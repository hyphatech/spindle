module S = Rowtype
module Pg = Rowtype_postgres

let ok = function
  | Ok v -> v
  | Error e -> Alcotest.failf "unexpected error: %s" (S.error_to_string e)

let connect ?statement_timeout_ms target =
  ok
    (Spindle_postgres.connect ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
       ~mono_clock:(Db_target.mono ()) ?statement_timeout_ms target)

let pool ?(size = 1) ?(wait_s = 2.) ?statement_cache target =
  ok
    (Spindle_postgres.Pool.create ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
       ~mono_clock:(Db_target.mono ()) ~size ~wait_s ?statement_cache target)

module T = Rowtype_postgres.Transaction

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || go (i + 1))
  in
  go 0

(* A transaction's answer, which the test expects to have landed. *)
let landed = function
  | Ok v -> v
  | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e)
  | Error (`Not_committed m) -> Alcotest.failf "not committed: %s" m

(* Two serializable transactions that each read what the other writes:
   the second to commit cannot be ordered after the first, and Postgres
   refuses it. Run again, it reads what the first committed and lands. *)
let test_a_lost_race_is_run_again () =
  let ( let* ) = Result.bind in
  Db_target.with_postgres (fun target ->
      let a = Db_target.connect target and b = Db_target.connect target in
      Fun.protect
        ~finally:(fun () ->
          Pg.close a;
          Pg.close b)
        (fun () ->
          ok (Pg.exec_raw a "create table t (n int)");
          let total db =
            Pg.run db
              (S.find ~params:S.unit ~row:S.int
                 "select coalesce(sum(n), 0)::int from t")
              ()
          in
          let write db n =
            Pg.run db (S.exec ~params:S.int "insert into t values ($1)") n
          in
          let attempts = ref 0 in
          let answer =
            T.within ~isolation:T.Serializable ~retries:1 a (fun a ->
                incr attempts;
                let* seen = total a in
                (* The other writer commits between this read and this
                   write, the first time only. *)
                let* () =
                  if !attempts > 1 then Ok ()
                  else
                    T.within ~isolation:T.Serializable b (fun b ->
                        let* seen = total b in
                        write b (seen + 1))
                in
                write a (seen + 10))
          in
          landed answer;
          Alcotest.(check int) "run twice" 2 !attempts;
          Alcotest.(check int) "each saw the other" 12 (ok (total a))))

(* A failure its retries did not get past is the client's to ask again, as a
   busy pool is: 503, not a 500 that says the server is broken. *)
let test_a_lost_race_answers_busy () =
  Alcotest.(check int)
    "503" 503
    (Spindle_http.Status.to_int
       (Spindle.Refusal.status
          (Spindle_postgres.refusal (`Not_serializable "could not serialize"))))

(* An overloaded pool says so within its wait, and serves the request once
   a connection is free again. The connection is held until the request
   has been answered, whatever either took. *)
let test_a_held_pool_is_busy_then_serves () =
  Db_target.with_postgres (fun target ->
      let pool = pool ~wait_s:0.2 target in
      let answer = ref None in
      let held, hold = Eio.Promise.create ()
      and answered, answer_given = Eio.Promise.create () in
      Eio.Fiber.both
        (fun () ->
          ignore
            (Spindle_postgres.Pool.use pool (fun _ ->
                 Eio.Promise.resolve hold ();
                 Ok (Eio.Promise.await answered))
              : (unit, _) result))
        (fun () ->
          Eio.Promise.await held;
          answer :=
            Some
              (Spindle_postgres.Pool.transaction pool (fun db ->
                   Pg.exec_raw db "select 1"));
          Eio.Promise.resolve answer_given ());
      (match !answer with
      | Some (Error `Busy) -> ()
      | Some (Ok ()) -> Alcotest.fail "served while the pool was held"
      | Some (Error _) | None -> Alcotest.fail "not busy");
      (match
         Spindle_postgres.Pool.transaction pool (fun db ->
             Pg.exec_raw db "select 1")
       with
      | Ok () -> ()
      | Error _ -> Alcotest.fail "not served once the pool was free");
      Spindle_postgres.Pool.close pool)

(* A program's pool is lent for as long as its body runs, and closed after:
   nothing idle is left holding a connection to the server. *)
let test_a_run_pool_is_closed_after () =
  Db_target.with_postgres (fun target ->
      let env = fst (Db_target.io ()) in
      let answer, pool =
        Spindle_postgres.Pool.run env target ~size:2 (fun pool ->
            let answer =
              Spindle_postgres.Pool.query pool
                (S.find_opt ~params:S.unit ~row:S.int "select 1")
                ()
            in
            (answer, pool))
      in
      (match answer with
      | Ok (Some 1) -> ()
      | _ -> Alcotest.fail "the pool was not lent");
      Alcotest.(check int)
        "nothing idle once closed" 0 (Spindle_postgres.Pool.stats pool).idle)

(* The driver's options reach it through both wrappers: a pool asked to
   keep no statements leaves none prepared at the server, where one left to
   the driver's default keeps what it ran. *)
let test_a_pool_takes_the_drivers_options () =
  Db_target.with_postgres (fun target ->
      let prepared ?statement_cache () =
        let pool = pool ?statement_cache target in
        let count =
          Spindle_postgres.Pool.use pool (fun db ->
              ignore
                (ok
                   (Pg.run db
                      (S.find_opt ~params:S.unit ~row:S.int "select 1")
                      ()));
              Pg.run db
                (S.find_opt ~params:S.unit ~row:S.int
                   "select count(*)::integer from pg_prepared_statements")
                ())
        in
        Spindle_postgres.Pool.close pool;
        count
      in
      match (prepared ~statement_cache:0 (), prepared ()) with
      | Ok (Some 0), Ok (Some n) when n > 0 -> ()
      | Ok (Some n), _ when n > 0 ->
          Alcotest.failf "%d statements kept by a pool asked to keep none" n
      | _ -> Alcotest.fail "the default pool kept no statement")

(* An instant goes into a timestamptz and comes back the same millisecond,
   before 1970 and on a day's edge as anywhere, through both of Postgres's
   formats; one past what Ptime holds is written as the nearest it can. *)
let test_an_instant_reads_back_to_the_millisecond () =
  let day = 86_400_000 in
  (* Years 1 to 9999: Ptime's range, but for its year 0, which the column
     refuses as it is written. *)
  let earliest = -62_135_596_800_000 and latest = 253_402_300_799_999 in
  let random =
    QCheck.Gen.generate ~n:200
      ~rand:(Random.State.make [| 7 |])
      (QCheck.Gen.int_range earliest latest)
  in
  let edges =
    [
      0;
      -1;
      1;
      day;
      day - 1;
      -day;
      -day - 1;
      earliest;
      latest;
      1_700_000_000_123;
    ]
  in
  Db_target.with_postgres (fun target ->
      List.iter
        (fun statement_cache ->
          let db =
            ok
              (Spindle_postgres.connect ~sw:(Db_target.sw ())
                 ~net:(Db_target.net ()) ~mono_clock:(Db_target.mono ())
                 ?statement_cache target)
          in
          let back ms =
            ok
              (Pg.run db
                 (S.find_opt ~params:Spindle_postgres.instant
                    ~row:Spindle_postgres.instant "select $1::timestamptz")
                 ms)
          in
          List.iter
            (fun ms ->
              Alcotest.(check (option int))
                (Printf.sprintf "%d reads back" ms)
                (Some ms) (back ms))
            (edges @ random);
          Alcotest.(check (option int))
            "past year 9999, the latest Ptime holds" (Some latest)
            (back (latest + day));
          Pg.close db)
        [ None; Some 0 ])

(* A connection that keeps no statements cannot bind for binary results, so
   it reads every scalar in text, and reads it as the binary path does. *)
let test_a_connection_that_keeps_no_statements_reads_text () =
  Db_target.with_postgres (fun target ->
      let db =
        ok
          (Spindle_postgres.connect ~sw:(Db_target.sw ())
             ~net:(Db_target.net ()) ~mono_clock:(Db_target.mono ())
             ~statement_cache:0 target)
      in
      let shape = S.(t5 int float text bool Spindle_postgres.instant) in
      let back =
        ok
          (Pg.run db
             (S.find_opt ~params:shape ~row:shape
                "select $1::integer, $2::double precision, $3::text, \
                 $4::boolean, $5::timestamptz")
             (42, 1.5, "hi", true, 1_700_000_000_123))
      in
      Pg.close db;
      match back with
      | Some (42, f, "hi", true, 1_700_000_000_123) when Float.equal f 1.5 -> ()
      | Some _ -> Alcotest.fail "a value read in text is not what was sent"
      | None -> Alcotest.fail "no row")

(* The pool as /readyz asks it: ready at rest, and ready while every
   connection is lent, since a server taken out of service for being busy is
   one taken out when it is needed most. *)
let test_a_busy_pool_is_ready () =
  Db_target.with_postgres (fun target ->
      let pool = pool target in
      let app =
        Spindle.Test.app
          (Spindle.Health.routes [ Spindle_postgres.Pool.check pool ])
      in
      let ready () = (Spindle.Test.call app `GET "/readyz").status in
      Alcotest.(check int) "at rest" 200 (ready ());
      let held = ref 0 in
      ignore
        (Spindle_postgres.Pool.use pool (fun _ -> Ok (held := ready ()))
          : (unit, _) result);
      Alcotest.(check int) "while every connection is lent" 200 !held;
      Spindle_postgres.Pool.close pool)

(* A statement run in a kept trace is a span of it, with its text and
   never its parameters. *)
let test_a_statement_is_a_span () =
  Db_target.with_postgres (fun target ->
      let pool = pool target in
      let spans = ref [] in
      let env = fst (Db_target.io ()) in
      let trace =
        Spindle.Trace.exporter ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env) (fun sp ->
            spans := sp :: !spans)
      in
      let answer =
        Spindle.Log.with_request_id ~trace "r-1" (fun () ->
            Spindle_postgres.Pool.transaction pool (fun db ->
                Pg.run db
                  (S.find ~params:S.text ~row:S.int "select length($1)::int")
                  "hunter2"))
      in
      Spindle_postgres.Pool.close pool;
      (match answer with
      | Ok n -> Alcotest.(check int) "the statement's answer" 7 n
      | Error _ -> Alcotest.fail "the statement failed");
      match List.rev !spans with
      | [ begin_; select; commit; request ] ->
          Alcotest.(check (list string))
            "each statement a span, by its text"
            [ "begin"; "select length($1)::int"; "commit" ]
            (List.filter_map
               (fun (sp : Spindle.Trace.span) ->
                 match List.assoc_opt "db.query.text" sp.attributes with
                 | Some (`String t) -> Some t
                 | Some (`Int _ | `Float _ | `Bool _) | None -> None)
               [ begin_; select; commit ]);
          Alcotest.(check bool)
            "a client span of the request's" true
            (List.for_all
               (fun (sp : Spindle.Trace.span) ->
                 String.equal sp.name "postgresql"
                 && sp.kind = Spindle.Trace.Client
                 && sp.parent_id = Some request.span_id)
               [ begin_; select; commit ]);
          Alcotest.(check bool)
            "and no parameter anywhere" false
            (List.exists
               (fun (sp : Spindle.Trace.span) ->
                 List.exists
                   (fun (_, v) ->
                     match v with
                     | `String v -> String.equal v "hunter2"
                     | `Int _ | `Float _ | `Bool _ -> false)
                   sp.attributes)
               !spans)
      | l -> Alcotest.failf "expected four spans, got %d" (List.length l))

(* A pool's connections are gauges read from its stats, one series per
   pool. *)
let test_a_pool_is_measured () =
  Db_target.with_postgres (fun target ->
      let main = pool ~size:2 target and replica = pool ~size:1 target in
      let metrics = Spindle.Metrics.create () in
      Spindle_postgres.Pool.measure main metrics;
      Spindle_postgres.Pool.measure ~name:"replica" replica metrics;
      let seen =
        Spindle_postgres.Pool.use main (fun _ ->
            Ok (Spindle.Metrics.exposition metrics))
      in
      Spindle_postgres.Pool.close main;
      Spindle_postgres.Pool.close replica;
      match seen with
      | Error `Busy -> Alcotest.fail "busy with nothing borrowed"
      | Ok text ->
          List.iter
            (fun line ->
              Alcotest.(check bool) line true (contains ~sub:line text))
            [
              {|db_client_connection_count{db_client_connection_pool_name="postgres",db_client_connection_state="idle"} 1|};
              {|db_client_connection_count{db_client_connection_pool_name="postgres",db_client_connection_state="used"} 1|};
              {|db_client_connection_count{db_client_connection_pool_name="replica",db_client_connection_state="idle"} 1|};
              {|db_client_connection_pending_requests{db_client_connection_pool_name="postgres"} 0|};
            ])

let test_a_pool_says_how_it_stands () =
  Db_target.with_postgres (fun target ->
      let pool = pool ~size:2 target in
      let held =
        Spindle_postgres.Pool.use pool (fun _ ->
            Ok (Spindle_postgres.Pool.stats pool))
      in
      let at_rest = Spindle_postgres.Pool.stats pool in
      Spindle_postgres.Pool.close pool;
      match held with
      | Error `Busy -> Alcotest.fail "busy with nothing borrowed"
      | Ok (held : Spindle_postgres.Pool.stats) ->
          Alcotest.(check (list int))
            "size, idle and waiting while one is borrowed" [ 2; 1; 0 ]
            [ held.size; held.idle; held.waiting ];
          Alcotest.(check int) "idle once it is back" 2 at_rest.idle)

(* A bound given when a connection is opened survives the connection being
   re-established, where a SET after connecting would not. *)
let test_a_revived_connection_keeps_its_bounds () =
  Db_target.with_postgres (fun target ->
      let db = connect ~statement_timeout_ms:150 target in
      Fun.protect
        ~finally:(fun () -> Pg.close db)
        (fun () ->
          let pid =
            ok
              (Pg.run db
                 (S.find_opt ~params:S.unit ~row:S.int "select pg_backend_pid()")
                 ())
          in
          Db_target.admin (fun admin ->
              ignore
                (ok
                   (Pg.run admin
                      (S.list ~params:S.int ~row:S.bool
                         "select pg_terminate_backend($1)")
                      (Option.value pid ~default:0))
                  : bool list));
          ignore (Pg.exec_raw db "select 1" : (unit, S.error) result);
          ok (Pg.revive db);
          (match Pg.exec_raw db "select pg_sleep(1)" with
          | Error _ -> ()
          | Ok () -> Alcotest.fail "the revived connection lost its bound");
          ok (Pg.exec_raw db "select 1")))

(* Every connection the framework opens is bounded unless told otherwise:
   a hung statement and a forgotten transaction are each ended by the
   server. *)
let test_a_connection_is_bounded_by_default () =
  Db_target.with_postgres (fun target ->
      let db = connect target in
      Fun.protect
        ~finally:(fun () -> Pg.close db)
        (fun () ->
          let show name =
            ok
              (Pg.run db
                 (S.find_opt ~params:S.unit ~row:S.text ("show " ^ name))
                 ())
          in
          Alcotest.(check (option string))
            "a statement" (Some "10s") (show "statement_timeout");
          Alcotest.(check (option string))
            "an idle transaction" (Some "30s")
            (show "idle_in_transaction_session_timeout")))

(* A borrow whose caller went away does not wait out its statement: the
   server is asked to stop it, and the one connection serves the next
   borrow. The statement would run for an hour, so a connection back within
   the pool's wait is one the server let go. *)
let test_an_abandoned_query_is_stopped_at_the_server () =
  Db_target.with_postgres (fun target ->
      let mono = Db_target.mono () in
      let pool = pool target in
      (match
         Eio.Time.Timeout.run (Eio.Time.Timeout.seconds mono 0.3) (fun () ->
             Ok
               (Spindle_postgres.Pool.use pool (fun db ->
                    Pg.exec_raw db "select pg_sleep(3600)")))
       with
      | Error `Timeout -> ()
      | Ok _ -> Alcotest.fail "the sleep was not abandoned");
      (match
         Spindle_postgres.Pool.use pool (fun db -> Pg.exec_raw db "select 1")
       with
      | Ok () -> ()
      | Error `Busy -> Alcotest.fail "the connection never came back"
      | Error (#S.error as e) ->
          Alcotest.failf "the connection came back broken: %s"
            (S.error_to_string e));
      Spindle_postgres.Pool.close pool)

(* An instant is read as the server writes it, so every connection the
   framework opens asks for ISO dates. *)
let test_a_connection_asks_for_iso_dates () =
  Db_target.with_postgres (fun target ->
      let db = connect target in
      Fun.protect
        ~finally:(fun () -> Pg.close db)
        (fun () ->
          match
            ok
              (Pg.run db
                 (S.find_opt ~params:S.unit ~row:S.text "show datestyle")
                 ())
          with
          | Some style ->
              Alcotest.(check bool)
                (Printf.sprintf "ISO, not %s" style)
                true
                (String.starts_with ~prefix:"ISO" style)
          | None -> Alcotest.fail "no date style"))

(* A server that takes the connection and never answers is given up on:
   the listener here completes the handshake from its backlog and says
   nothing more, so a connect that returns at all was given up. *)
let test_a_silent_server_is_given_up_on () =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close listener)
    (fun () ->
      Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      Unix.listen listener 8;
      let port =
        match Unix.getsockname listener with
        | Unix.ADDR_INET (_, p) -> p
        | Unix.ADDR_UNIX _ -> Alcotest.fail "expected a TCP socket"
      in
      match
        Spindle_postgres.connect ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
          ~mono_clock:(Db_target.mono ()) ~connect_timeout_s:1
          (Printf.sprintf "postgres://nobody@127.0.0.1:%d/none?sslmode=disable"
             port)
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "connected to nothing")

(* A transaction around a route's work: the bracket is a function the
   handler calls, so its read and its write are one transaction, a refusal
   rolls back unless the work says to keep it, and what follows the commit
   is the line after the bracket. Each case gets a counter at zero. *)
let with_counter_pool f =
  Db_target.with_postgres (fun target ->
      let pool = pool ~size:2 target in
      (match
         Spindle_postgres.Pool.use pool (fun db ->
             Pg.exec_raw db
               "create table counter (n integer not null); insert into counter \
                values (0)")
       with
      | Ok () -> ()
      | Error `Busy -> Alcotest.fail "no connection"
      | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e));
      Fun.protect
        ~finally:(fun () -> Spindle_postgres.Pool.close pool)
        (fun () -> f pool))

let counted pool =
  match
    Spindle_postgres.Pool.query pool
      (S.find_opt ~params:S.unit ~row:S.int "select n from counter")
      ()
  with
  | Ok (Some n) -> n
  | Ok None | Error _ -> Alcotest.fail "no counter"

let refused_code =
  Spindle.Refusal.Code.make "refused" ~status:`Conflict ~doc:"A test's."

(* The counter read and bumped, and the transaction each was done in. *)
let bumped db =
  let ( let* ) = Result.bind in
  let* read =
    Pg.run db
      (S.find_opt ~params:S.unit
         ~row:S.(t2 int int)
         "select n, txid_current()::int from counter")
      ()
  in
  match read with
  | None -> Ok None
  | Some (n, read_in) ->
      let* written_in =
        Pg.run db
          (S.find_opt ~params:S.int ~row:S.int
             "update counter set n = $1 returning txid_current()::int")
          (n + 1)
      in
      Ok (Some [ n + 1; read_in; Option.value written_in ~default:0 ])

let bump ?(keep_refused = false) ~refuse ~after pool =
  let open Spindle.Syntax in
  Spindle.post ~refuses:[ refused_code ]
    Spindle.Path.(s "bump")
    (Spindle.Returns.json Wiretype.(list int))
    (let+ () = Spindle.Dep.return () in
     match
       Spindle_postgres.Pool.transaction pool
         ~keep:(function `Refused _ -> keep_refused | _ -> false)
         (fun db ->
           match bumped db with
           | Error e -> Error e
           | Ok None -> Error `No_counter
           | Ok (Some v) when not refuse -> Ok v
           | Ok (Some _) ->
               Error
                 (`Refused (Spindle.Refusal.make refused_code "Not this time.")))
     with
     | Ok v ->
         after := true;
         Ok v
     | Error (`Refused r) -> Error r
     | Error `No_counter ->
         Error (Spindle.Refusal.internal ~detail:"no counter")
     | Error (#Spindle_postgres.error as e) ->
         Error (Spindle_postgres.refusal e))

let call route =
  match Spindle.App.make [ route ] with
  | Error m -> Alcotest.fail m
  | Ok app -> Spindle.Test.call app `POST "/bump"

let test_a_read_and_a_write_are_one_transaction () =
  with_counter_pool (fun pool ->
      let after = ref false in
      let r = call (bump ~refuse:false ~after pool) in
      Alcotest.(check int) "answered" 200 r.status;
      (match Yojson.Safe.from_string r.body with
      | `List [ `Int n; `Int read_in; `Int written_in ] ->
          Alcotest.(check int) "the value" 1 n;
          Alcotest.(check int) "one transaction" read_in written_in
      | _ -> Alcotest.failf "unexpected body %s" r.body);
      Alcotest.(check int) "kept" 1 (counted pool);
      Alcotest.(check bool) "and what came after ran" true !after)

let test_a_refused_bracket_keeps_nothing_unless_it_says () =
  with_counter_pool (fun pool ->
      let after = ref false in
      let r = call (bump ~refuse:true ~after pool) in
      Alcotest.(check int) "refused" 409 r.status;
      Alcotest.(check int) "rolled back" 0 (counted pool);
      Alcotest.(check bool) "and nothing came after" false !after;
      let r = call (bump ~keep_refused:true ~refuse:true ~after pool) in
      Alcotest.(check int) "refused again" 409 r.status;
      Alcotest.(check int) "kept, where the work says" 1 (counted pool);
      Alcotest.(check bool) "still nothing after a refusal" false !after)

(* The table is the application's to make, from the schema it is given, and
   every statement the store runs is one the database agrees with. *)
let test_sessions_are_kept_in_a_table () =
  Db_target.with_postgres (fun target ->
      let db = Db_target.connect target in
      Fun.protect
        ~finally:(fun () -> Pg.close db)
        (fun () ->
          ok
            (Pg.exec_raw db (Spindle_postgres.Session.schema ~table:"sessions"));
          (match
             Pg.verify db
               (Spindle_postgres.Session.statements ~table:"sessions")
           with
          | Ok () -> ()
          | Error (`Disagreements ms) -> Alcotest.fail (String.concat "; " ms)
          | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e));
          let store =
            Spindle_postgres.Session.store (pool target) ~table:"sessions"
          in
          let entry expires_ms =
            {
              Spindle.Session.data = {|"kim"|};
              created_ms = 1_000;
              seen_ms = 2_000;
              expires_ms;
            }
          in
          let got = function Ok v -> v | Error m -> Alcotest.fail m in
          got (store.save "d1" (entry 10_000));
          got (store.save "d2" (entry 5_000));
          (match got (store.find "d1") with
          | Some e ->
              Alcotest.(check string) "its data" {|"kim"|} e.data;
              Alcotest.(check int)
                "its instants, to the millisecond" 10_000 e.expires_ms
          | None -> Alcotest.fail "the session was not kept");
          got (store.save "d1" { (entry 20_000) with seen_ms = 3_000 });
          Alcotest.(check (option int))
            "a save replaces" (Some 3_000)
            (Option.map
               (fun (e : Spindle.Session.entry) -> e.seen_ms)
               (got (store.find "d1")));
          Alcotest.(check int)
            "a sweep deletes what has expired" 1
            (got (store.sweep ~now:6_000));
          got (store.delete "d1");
          Alcotest.(check bool)
            "and a delete, what it names" true
            (Option.is_none (got (store.find "d1")));
          Alcotest.(check bool)
            "a table that is no name is refused" true
            (match Spindle_postgres.Session.schema ~table:"x; drop" with
            | _ -> false
            | exception Invalid_argument _ -> true)))

let () =
  Db_target.required ~suite:"spindle_postgres";
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Db_target.eio env ~sw;
  Alcotest.run ~and_exit:false "spindle_postgres"
    [
      ( "transactions",
        [
          Alcotest.test_case "a lost race is run again" `Quick
            test_a_lost_race_is_run_again;
          Alcotest.test_case "a lost race answers busy" `Quick
            test_a_lost_race_answers_busy;
          Alcotest.test_case "a held pool is busy, then serves" `Quick
            test_a_held_pool_is_busy_then_serves;
          Alcotest.test_case "a pool takes the driver's options" `Quick
            test_a_pool_takes_the_drivers_options;
          Alcotest.test_case "a run pool is closed after" `Quick
            test_a_run_pool_is_closed_after;
          Alcotest.test_case "a connection that keeps no statements reads text"
            `Quick test_a_connection_that_keeps_no_statements_reads_text;
          Alcotest.test_case "an instant reads back to the millisecond" `Quick
            test_an_instant_reads_back_to_the_millisecond;
          Alcotest.test_case "a statement is a span" `Quick
            test_a_statement_is_a_span;
          Alcotest.test_case "a pool is measured" `Quick test_a_pool_is_measured;
          Alcotest.test_case "a pool says how it stands" `Quick
            test_a_pool_says_how_it_stands;
          Alcotest.test_case "a busy pool is ready" `Quick
            test_a_busy_pool_is_ready;
          Alcotest.test_case "a revived connection keeps its bounds" `Quick
            test_a_revived_connection_keeps_its_bounds;
          Alcotest.test_case "a connection is bounded by default" `Quick
            test_a_connection_is_bounded_by_default;
          Alcotest.test_case "an abandoned query is stopped at the server"
            `Quick test_an_abandoned_query_is_stopped_at_the_server;
          Alcotest.test_case "a connection asks for ISO dates" `Quick
            test_a_connection_asks_for_iso_dates;
          Alcotest.test_case "a silent server is given up on" `Quick
            test_a_silent_server_is_given_up_on;
        ] );
      ( "brackets",
        [
          Alcotest.test_case "a read and a write are one transaction" `Quick
            test_a_read_and_a_write_are_one_transaction;
          Alcotest.test_case "a refused bracket keeps nothing unless it says"
            `Quick test_a_refused_bracket_keeps_nothing_unless_it_says;
        ] );
      ( "sessions",
        [
          Alcotest.test_case "sessions are kept in a table" `Quick
            test_sessions_are_kept_in_a_table;
        ] );
    ]
