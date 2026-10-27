module S = Rowtype
module Pg = Rowtype_postgres

let ok = function
  | Ok v -> v
  | Error e -> Alcotest.failf "unexpected error: %s" (S.error_to_string e)

let connect ?statement_timeout ?idle_in_transaction_timeout target =
  ok
    (Spindle_postgres.connect ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
       ~mono_clock:(Db_target.mono ()) ?statement_timeout
       ?idle_in_transaction_timeout target)

let pool ?(size = 1) ?(wait = Mtime.Span.(2 * s)) ?statement_cache target =
  ok
    (Spindle_postgres.Pool.create ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
       ~mono_clock:(Db_target.mono ()) ~size ~wait ?statement_cache target)

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

(* A failure is told in rowtype's words: a statement's as
   [Rowtype.error_to_string] tells it, and a transaction's and a pool's own as
   rowtype's printers do, so one failure reads the same whichever library
   logs it. *)
let test_every_failure_has_its_words () =
  let told what expected e =
    Alcotest.(check string) what expected (Spindle_postgres.error_to_string e)
  in
  List.iter
    (fun e -> told "a statement's failure" (S.error_to_string e) e)
    [
      `Conflict (Some "users_email_key");
      `Conflict None;
      `Not_serializable "could not serialize access";
      `Lost "the connection timed out";
      `Db "relation \"users\" does not exist";
    ];
  told "not committed"
    "the transaction was not committed: commit: the server refused it"
    (`Not_committed "commit: the server refused it");
  told "busy" "no connection came free within the pool's wait" (`Pool `Busy);
  told "pool closed" "the pool is closed" (`Pool `Closed)

(* A pool closed under a request is a server shutting down: 503, as a busy
   pool is, not a 500 that says the server is broken. *)
let test_a_closed_pool_answers_busy () =
  Alcotest.(check int)
    "503" 503
    (Spindle_http.Status.to_int
       (Spindle.Refusal.status (Spindle_postgres.refusal (`Pool `Closed))))

(* A database nobody answers for did nothing, so asking again is what may
   succeed: 503 busy, as a busy pool is, and the client told when. *)
let test_an_unreachable_database_answers_busy () =
  let port =
    let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close s)
      (fun () ->
        Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
        match Unix.getsockname s with
        | Unix.ADDR_INET (_, p) -> p
        | Unix.ADDR_UNIX _ -> Alcotest.fail "expected a TCP socket")
  in
  match
    Spindle_postgres.connect ~sw:(Db_target.sw ()) ~net:(Db_target.net ())
      ~mono_clock:(Db_target.mono ())
      (Db_target.conninfo
         (Printf.sprintf "postgres://nobody@127.0.0.1:%d/none?sslmode=disable"
            port))
  with
  | Ok _ -> Alcotest.fail "connected to nothing"
  | Error e ->
      Alcotest.(check bool)
        "unsent" true
        (match e with `Unsent _ -> true | _ -> false);
      let r = Spindle_postgres.refusal e in
      Alcotest.(check int)
        "503" 503
        (Spindle_http.Status.to_int (Spindle.Refusal.status r));
      Alcotest.(check string) "busy" "busy" (Spindle.Refusal.Code.name r.code)

(* A statement on a connection its owner closed sent nothing, and is the
   server's own fault: a 500 with why in the log, not a 503 that asks the
   client to come back. *)
let test_a_closed_connection_answers_internal () =
  Db_target.with_postgres (fun target ->
      let db = connect target in
      Pg.close db;
      match Pg.exec_raw db "select 1" with
      | Ok () -> Alcotest.fail "ran on a closed connection"
      | Error e ->
          Alcotest.(check string)
            "its words" "the connection is closed"
            (Spindle_postgres.error_to_string e);
          Alcotest.(check int)
            "500" 500
            (Spindle_http.Status.to_int
               (Spindle.Refusal.status (Spindle_postgres.refusal e))))

(* A failure its retries did not get past is the client's to ask again, as a
   busy pool is: 503, not a 500 that says the server is broken. *)
let test_a_lost_race_answers_busy () =
  Alcotest.(check int)
    "503" 503
    (Spindle_http.Status.to_int
       (Spindle.Refusal.status
          (Spindle_postgres.refusal (`Not_serializable "could not serialize"))))

(* A pool with no connection free is a server under load, not a broken one:
   its 503 is a warning, saying why, and nothing is an error. *)
let test_an_exhausted_pool_is_a_warning () =
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let busy =
    Spindle.get
      Spindle.Path.(s "busy")
      Spindle.Returns.text
      (Spindle.Dep.return (Error (Spindle_postgres.refusal (`Pool `Busy))))
  in
  let r = Spindle.Test.call (Spindle.Test.app [ busy ]) `GET "/busy" in
  Alcotest.(check int) "503" 503 (Spindle_http.Status.to_int r.status);
  Alcotest.(check bool)
    "why is a warning" true
    (List.exists
       (fun l ->
         contains ~sub:{|"level":"warn"|} l
         && contains ~sub:"no database connection" l)
       !lines);
  Alcotest.(check bool)
    "and nothing is an error" false
    (List.exists (contains ~sub:{|"level":"error"|}) !lines)

(* An overloaded pool says so within its wait, and serves the request once
   a connection is free again. The connection is held until the request
   has been answered, whatever either took. *)
let test_a_held_pool_is_busy_then_serves () =
  Db_target.with_postgres (fun target ->
      let pool = pool ~wait:Mtime.Span.(200 * ms) target in
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
      | Some (Error (`Pool `Busy)) -> ()
      | Some (Ok ()) -> Alcotest.fail "served while the pool was held"
      | Some (Error _) | None -> Alcotest.fail "not busy");
      (match
         Spindle_postgres.Pool.transaction pool (fun db ->
             Pg.exec_raw db "select 1")
       with
      | Ok () -> ()
      | Error _ -> Alcotest.fail "not served once the pool was free");
      Spindle_postgres.Pool.close pool)

(* A closed pool will never lend again, so a borrow is told so at once
   rather than waiting out the wait for nothing. The wait is ten minutes:
   a borrow that waited would hold the suite far past any runner's
   patience, however fast the machine. *)
let test_a_closed_pool_answers_closed_at_once () =
  Db_target.with_postgres (fun target ->
      let pool = pool ~wait:Mtime.Span.(10 * min) target in
      Spindle_postgres.Pool.close pool;
      match
        Spindle_postgres.Pool.exec pool (S.exec ~params:S.unit "select 1") ()
      with
      | Error (`Pool `Closed) -> ()
      | Error (`Pool `Busy) -> Alcotest.fail "a closed pool answered busy"
      | Error _ | Ok () -> Alcotest.fail "a closed pool lent a connection")

(* A program's pool is lent for as long as its body runs, and closed after:
   nothing idle is left holding a connection to the server. *)
let test_a_run_pool_is_closed_after () =
  Db_target.with_postgres (fun target ->
      let env = fst (Db_target.io ()) in
      let answer, pool =
        Spindle_postgres.Pool.run env (Pg.Conninfo.to_url target) ~size:2
          (fun pool ->
            let answer =
              Spindle_postgres.Pool.exec pool
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

(* A program's pool whose fiber is cancelled -- a race it lost, a sibling
   that failed -- passes the cancellation on as it came, so whatever
   cancelled it goes on as if the pool had never been there. *)
let test_a_cancelled_run_pool_passes_the_cancellation_on () =
  Db_target.with_postgres (fun target ->
      let env = fst (Db_target.io ()) in
      let opened, opening = Eio.Promise.create () in
      let winner =
        Eio.Fiber.first
          (fun () ->
            Spindle_postgres.Pool.run env (Pg.Conninfo.to_url target) ~size:3
              (fun _ ->
                Eio.Promise.resolve opening ();
                Eio.Fiber.await_cancel ()))
          (fun () ->
            Eio.Promise.await opened;
            "the sibling")
      in
      Alcotest.(check string) "the race is the sibling's" "the sibling" winner)

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
   formats: the text one reads it as a connection's DateStyle has the server
   write it. *)
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
          let back t =
            ok
              (Pg.run db
                 (S.find_opt ~params:S.instant ~row:S.instant
                    "select $1::timestamptz")
                 t)
          in
          List.iter
            (fun ms ->
              let t = Instants.of_ms ms in
              Alcotest.(check (option Instants.testable))
                (Printf.sprintf "%d reads back" ms)
                (Some t) (back t))
            (edges @ random);
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
      let shape = S.(t5 int float text bool instant) in
      let instant = Instants.of_ms 1_700_000_000_123 in
      let back =
        ok
          (Pg.run db
             (S.find_opt ~params:shape ~row:shape
                "select $1::integer, $2::double precision, $3::text, \
                 $4::boolean, $5::timestamptz")
             (42, 1.5, "hi", true, instant))
      in
      Pg.close db;
      match back with
      | Some (42, f, "hi", true, t)
        when Float.equal f 1.5 && Ptime.equal t instant ->
          ()
      | Some _ -> Alcotest.fail "a value read in text is not what was sent"
      | None -> Alcotest.fail "no row")

let db : Spindle_postgres.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

(* The store over [table] as a route reads it, through the pool's resource:
   kept from one request, its calls run on [pool] after it as during. *)
let store_of pool ?table () =
  let open Spindle.Syntax in
  let read = Spindle_postgres.Session.store ?table db and kept = ref None in
  let app =
    Spindle.Test.app
      ~resources:[ Spindle.Dep.resource db pool ]
      [
        Spindle.get Spindle.Path.root Spindle.Returns.text
          (let+ store = read in
           kept := Some store;
           Ok "kept");
      ]
  in
  ignore (Spindle.Test.call app `GET "/");
  match !kept with Some store -> store | None -> Alcotest.fail "no store"

(* The pool as /readyz asks it: ready at rest, and ready while every
   connection is lent, since a server taken out of service for being busy is
   one taken out when it is needed most. *)
let test_a_busy_pool_is_ready () =
  Db_target.with_postgres (fun target ->
      let pool = pool target in
      let app =
        Spindle.Test.app
          ~resources:[ Spindle.Dep.resource db pool ]
          (Spindle.Health.routes [ Spindle_postgres.Pool.check db ])
      in
      let ready () =
        Spindle_http.Status.to_int (Spindle.Test.call app `GET "/readyz").status
      in
      Alcotest.(check int) "at rest" 200 (ready ());
      let held = ref 0 in
      ignore
        (Spindle_postgres.Pool.use pool (fun _ -> Ok (held := ready ()))
          : (unit, _) result);
      Alcotest.(check int) "while every connection is lent" 200 !held;
      Spindle_postgres.Pool.close pool)

(* A closed pool has nothing idle either, but nothing it holds is lent:
   it can serve nobody, so /readyz says so rather than reading it as
   busy. *)
let test_a_closed_pool_is_not_ready () =
  Db_target.with_postgres (fun target ->
      let pool = pool target in
      let app =
        Spindle.Test.app
          ~resources:[ Spindle.Dep.resource db pool ]
          (Spindle.Health.routes [ Spindle_postgres.Pool.check db ])
      in
      Spindle_postgres.Pool.close pool;
      Alcotest.(check int)
        "once closed" 503
        (Spindle_http.Status.to_int
           (Spindle.Test.call app `GET "/readyz").status))

(* A user filters a library's log by the name they installed. *)
let test_the_log_source_is_the_librarys_name () =
  let names = List.map Logs.Src.name (Logs.Src.list ()) in
  Alcotest.(check bool)
    "spindle-postgres is a source" true
    (List.exists (String.equal "spindle-postgres") names);
  Alcotest.(check bool)
    "spindle.postgres is not" false
    (List.exists (String.equal "spindle.postgres") names)

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
      | Error (`Pool _) -> Alcotest.fail "busy with nothing borrowed"
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
      | Error (`Pool _) -> Alcotest.fail "busy with nothing borrowed"
      | Ok (held : Spindle_postgres.Pool.stats) ->
          Alcotest.(check (list int))
            "size, idle and waiting while one is borrowed" [ 2; 1; 0 ]
            [ held.size; held.idle; held.waiting ];
          Alcotest.(check int) "idle once it is back" 2 at_rest.idle)

(* A bound given when a connection is opened survives the connection being
   re-established, where a SET after connecting would not. *)
let test_a_revived_connection_keeps_its_bounds () =
  Db_target.with_postgres (fun target ->
      let db = connect ~statement_timeout:Mtime.Span.(150 * ms) target in
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
          (match Pg.exec_raw db "select pg_sleep(3600)" with
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

(* A bound is written in whole milliseconds, rounded up, as Postgres reads
   one: a span under a millisecond is still a bound, never the 0 that lifts
   it. *)
let test_a_bound_is_whole_milliseconds_rounded_up () =
  Db_target.with_postgres (fun target ->
      let db =
        connect
          ~statement_timeout:Mtime.Span.(Mtime.Span.add (2_500 * ms) ns)
          ~idle_in_transaction_timeout:Mtime.Span.ns target
      in
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
            "a statement" (Some "2501ms") (show "statement_timeout");
          Alcotest.(check (option string))
            "an idle transaction" (Some "1ms")
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
         Eio.Time.Timeout.run
           (Eio.Time.Timeout.v mono Mtime.Span.(300 * ms))
           (fun () ->
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
      | Error (`Pool _) -> Alcotest.fail "the connection never came back"
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
          ~mono_clock:(Db_target.mono ())
          (Db_target.conninfo
             (Printf.sprintf
                "postgres://nobody@127.0.0.1:%d/none?sslmode=disable&connect_timeout=1"
                port))
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
      | Error (`Pool _) -> Alcotest.fail "no connection"
      | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e));
      Fun.protect
        ~finally:(fun () -> Spindle_postgres.Pool.close pool)
        (fun () -> f pool))

let counted pool =
  match
    Spindle_postgres.Pool.exec pool
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

let call route = Spindle.Test.call (Spindle.Test.app [ route ]) `POST "/bump"

let test_a_read_and_a_write_are_one_transaction () =
  with_counter_pool (fun pool ->
      let after = ref false in
      let r = call (bump ~refuse:false ~after pool) in
      Alcotest.(check int) "answered" 200 (Spindle_http.Status.to_int r.status);
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
      Alcotest.(check int) "refused" 409 (Spindle_http.Status.to_int r.status);
      Alcotest.(check int) "rolled back" 0 (counted pool);
      Alcotest.(check bool) "and nothing came after" false !after;
      let r = call (bump ~keep_refused:true ~refuse:true ~after pool) in
      Alcotest.(check int)
        "refused again" 409
        (Spindle_http.Status.to_int r.status);
      Alcotest.(check int) "kept, where the work says" 1 (counted pool);
      Alcotest.(check bool) "still nothing after a refusal" false !after)

let taken = Spindle.Refusal.Code.make "taken" ~status:`Conflict ~doc:"A test's."

(* A route that claims one name twice in one transaction, and answers the
   unique key's conflict with a code it declares, as a route expecting one
   does. *)
let claim_twice pool =
  let open Spindle.Syntax in
  Spindle.post ~refuses:[ taken ]
    Spindle.Path.(s "claim")
    (Spindle.Returns.empty ())
    (let+ () = Spindle.Dep.return () in
     let claim db =
       Pg.run db (S.exec ~params:S.text "insert into names values ($1)") "a"
     in
     match
       Spindle_postgres.Pool.transaction pool (fun db ->
           let ( let* ) = Result.bind in
           let* () = claim db in
           claim db)
     with
     | Ok () -> Ok ()
     | Error (`Conflict (Some "names_name_key")) ->
         Error (Spindle.Refusal.make taken "That name is taken.")
     | Error e -> Error (Spindle_postgres.refusal e))

(* A unique key checked at [COMMIT] refuses the same write as one checked at
   the statement, and the route that handles the one handles the other. *)
let test_a_deferred_conflict_answers_as_a_statement's_does () =
  List.iter
    (fun (checked, constraint_) ->
      Db_target.with_postgres (fun target ->
          let pool = pool target in
          Fun.protect
            ~finally:(fun () -> Spindle_postgres.Pool.close pool)
            (fun () ->
              (match
                 Spindle_postgres.Pool.use pool (fun db ->
                     Pg.exec_raw db
                       ("create table names (name text, constraint \
                         names_name_key unique (name) " ^ constraint_ ^ ")"))
               with
              | Ok () -> ()
              | Error (`Pool _) -> Alcotest.fail "no connection"
              | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e));
              let app = Spindle.Test.app [ claim_twice pool ] in
              let r = Spindle.Test.call app `POST "/claim" in
              Alcotest.(check int)
                checked 409
                (Spindle_http.Status.to_int r.status);
              match
                Spindle_postgres.Pool.exec pool
                  (S.find ~params:S.unit ~row:S.int
                     "select count(*)::int from names")
                  ()
              with
              | Ok n -> Alcotest.(check int) "rolled back" 0 n
              | Error _ -> Alcotest.fail "no count")))
    [
      ("checked at the statement", "");
      ("checked at commit", "deferrable initially deferred");
    ]

(* A store's failure is the pool's own words, as every library tells it, so
   one failure reads the same in the store's log as anywhere else. Its one
   connection is held while the store asks, so the store's borrow finds none
   whatever the machine's speed. *)
let test_a_stores_busy_pool_reads_as_the_pools_words () =
  Db_target.with_postgres (fun target ->
      let pool = pool ~wait:Mtime.Span.(50 * ms) target in
      let store = store_of pool ~table:"sessions" () in
      let answer =
        Spindle_postgres.Pool.use pool (fun _ -> Ok (store.find "d1"))
      in
      Spindle_postgres.Pool.close pool;
      match answer with
      | Ok (Error m) ->
          Alcotest.(check string)
            "the pool's words"
            (Pg.error_to_string (`Pool `Busy))
            m
      | Ok (Ok _) -> Alcotest.fail "the store found a connection"
      | Error _ -> Alcotest.fail "the test's own borrow failed")

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
               (Spindle_postgres.Session.statements ~table:"sessions" ())
           with
          | Ok () -> ()
          | Error (`Disagreements ms) -> Alcotest.fail (String.concat "; " ms)
          | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e));
          let store = store_of (pool target) ~table:"sessions" () in
          let entry expires =
            {
              Spindle.Session.data = {|"kim"|};
              created = Instants.of_ms 1_000;
              seen = Instants.of_ms 2_000;
              expires = Instants.of_ms expires;
            }
          in
          let got = function Ok v -> v | Error m -> Alcotest.fail m in
          got (store.save "d1" (entry 10_000));
          got (store.save "d2" (entry 5_000));
          (match got (store.find "d1") with
          | Some e ->
              Alcotest.(check string) "its data" {|"kim"|} e.data;
              Alcotest.check Instants.testable
                "its instants, to the millisecond" (Instants.of_ms 10_000)
                e.expires
          | None -> Alcotest.fail "the session was not kept");
          got
            (store.save "d1"
               { (entry 20_000) with seen = Instants.of_ms 3_000 });
          Alcotest.(check (option Instants.testable))
            "a save replaces"
            (Some (Instants.of_ms 3_000))
            (Option.map
               (fun (e : Spindle.Session.entry) -> e.seen)
               (got (store.find "d1")));
          got (store.save "d3" (entry 4_000));
          Alcotest.(check int)
            "a sweep stops at its limit" 1
            (got (store.sweep ~now:(Instants.of_ms 6_000) ~limit:1));
          Alcotest.(check bool)
            "having taken the soonest ended" true
            (Option.is_none (got (store.find "d3"))
            && Option.is_some (got (store.find "d2")));
          Alcotest.(check int)
            "and the next takes the rest that ended" 1
            (got (store.sweep ~now:(Instants.of_ms 6_000) ~limit:10));
          got (store.delete "d1");
          Alcotest.(check bool)
            "and a delete, what it names" true
            (Option.is_none (got (store.find "d1")));
          Alcotest.(check bool)
            "a table that is no name is refused" true
            (match Spindle_postgres.Session.schema ~table:"x; drop" with
            | _ -> false
            | exception Invalid_argument _ -> true)))

(* Sessions kept in a table read the pool as every route does, so they and
   the routes that use them are values made before the pool, which the
   server is handed. *)
let test_sessions_read_the_pool_as_a_resource () =
  Db_target.with_postgres (fun target ->
      let open Spindle.Syntax in
      let connection = Db_target.connect target in
      ok
        (Pg.exec_raw connection
           (Spindle_postgres.Session.schema ~table:"visits"));
      Pg.close connection;
      let session =
        Spindle.Session.create
          ~store:(Spindle_postgres.Session.store db ~table:"visits")
          ~idle:Mtime.Span.hour ~absolute:Mtime.Span.day Wiretype.string
      in
      let routes =
        [
          Spindle.post
            Spindle.Path.(s "sign-in")
            Spindle.Returns.text
            (let+ session = session in
             match Spindle.Session.put session "kim" with
             | Ok () -> Ok "in"
             | Error e -> Error e);
          Spindle.get
            Spindle.Path.(s "me")
            Spindle.Returns.text
            (let+ session = session in
             match Spindle.Session.get session with
             | Ok (Some user) -> Ok user
             | Ok None -> Ok "nobody"
             | Error e -> Error e);
        ]
      in
      let pool = pool target in
      let b =
        Spindle.Test.browser
          (Spindle.Test.app ~resources:[ Spindle.Dep.resource db pool ] routes)
      in
      ignore (Spindle.Test.Browser.call b `POST "/sign-in");
      Alcotest.(check string)
        "found in the table" "kim" (Spindle.Test.Browser.call b `GET "/me").body;
      Spindle_postgres.Pool.close pool)

let migration =
  "../postgres/migrations/20261021000000_create_spindle_sessions.sql"

(* The migration the package installs is written from the schema, held to
   it, and makes the table a store reads by default. *)
let test_the_installed_migration_is_the_schema () =
  let text = In_channel.with_open_bin migration In_channel.input_all in
  Alcotest.(check bool)
    "it ends in the schema of the default table" true
    (String.ends_with
       ~suffix:
         (Spindle_postgres.Session.schema
            ~table:Spindle_postgres.Session.default_table)
       text);
  Db_target.with_postgres (fun target ->
      let c = Db_target.connect target in
      Fun.protect
        ~finally:(fun () -> Pg.close c)
        (fun () ->
          ok (Pg.exec_raw c text);
          match Pg.verify c (Spindle_postgres.Session.statements ()) with
          | Ok () -> ()
          | Error (`Disagreements ms) -> Alcotest.fail (String.concat "; " ms)
          | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e));
      let store = store_of (pool target) () in
      match
        store.save "d1"
          {
            Spindle.Session.data = {|"kim"|};
            created = Instants.of_ms 1_000;
            seen = Instants.of_ms 2_000;
            expires = Instants.of_ms 10_000;
          }
      with
      | Ok () -> ()
      | Error m -> Alcotest.fail m)

(* A table's name is a constant written in source, so one that is no name
   is refused where the store is made, as the program starts, never as a
   request's 500. *)
let test_a_stores_table_is_checked_where_it_is_made () =
  Alcotest.(check bool)
    "refused at once" true
    (match Spindle_postgres.Session.store db ~table:"x; drop" with
    | _ -> false
    | exception Invalid_argument _ -> true)

(* A lowercase identifier is a table's name even where SQL reserves it as
   a word: [user] and [order] are tables an application names. *)
let test_a_reserved_word_is_a_table's_name () =
  Db_target.with_postgres (fun target ->
      let db = Db_target.connect target in
      Fun.protect
        ~finally:(fun () -> Pg.close db)
        (fun () ->
          ok (Pg.exec_raw db (Spindle_postgres.Session.schema ~table:"user"));
          (match
             Pg.verify db (Spindle_postgres.Session.statements ~table:"user" ())
           with
          | Ok () -> ()
          | Error (`Disagreements ms) -> Alcotest.fail (String.concat "; " ms)
          | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e));
          let store = store_of (pool target) ~table:"user" () in
          let got = function Ok v -> v | Error m -> Alcotest.fail m in
          got
            (store.save "d1"
               {
                 Spindle.Session.data = {|"kim"|};
                 created = Instants.of_ms 1_000;
                 seen = Instants.of_ms 2_000;
                 expires = Instants.of_ms 10_000;
               });
          Alcotest.(check (option string))
            "kept in it" (Some {|"kim"|})
            (Option.map
               (fun (e : Spindle.Session.entry) -> e.data)
               (got (store.find "d1")))))

(* A name as long as Postgres keeps one is a table's name too: its index,
   named after it, would be cut to the same 63 bytes and collide. *)
let test_the_longest_name_is_a_table's_name () =
  Db_target.with_postgres (fun target ->
      let db = Db_target.connect target in
      Fun.protect
        ~finally:(fun () -> Pg.close db)
        (fun () ->
          List.iter
            (fun n ->
              let table = String.make n 's' in
              ok (Pg.exec_raw db (Spindle_postgres.Session.schema ~table));
              match
                Pg.verify db (Spindle_postgres.Session.statements ~table ())
              with
              | Ok () -> ()
              | Error (`Disagreements ms) ->
                  Alcotest.fail (String.concat "; " ms)
              | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e))
            [ 52; 53; 63 ]))

let () =
  Db_target.required ~suite:"spindle-postgres";
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Db_target.eio env ~sw;
  Alcotest.run ~and_exit:false "spindle-postgres"
    [
      ( "transactions",
        [
          Alcotest.test_case "a lost race is run again" `Quick
            test_a_lost_race_is_run_again;
          Alcotest.test_case "a lost race answers busy" `Quick
            test_a_lost_race_answers_busy;
          Alcotest.test_case "a closed connection answers internal" `Quick
            test_a_closed_connection_answers_internal;
          Alcotest.test_case "a closed pool answers busy" `Quick
            test_a_closed_pool_answers_busy;
          Alcotest.test_case "an exhausted pool is a warning" `Quick
            test_an_exhausted_pool_is_a_warning;
          Alcotest.test_case "a held pool is busy, then serves" `Quick
            test_a_held_pool_is_busy_then_serves;
          Alcotest.test_case "a closed pool answers closed at once" `Quick
            test_a_closed_pool_answers_closed_at_once;
          Alcotest.test_case "a pool takes the driver's options" `Quick
            test_a_pool_takes_the_drivers_options;
          Alcotest.test_case "a run pool is closed after" `Quick
            test_a_run_pool_is_closed_after;
          Alcotest.test_case "a cancelled run pool passes the cancellation on"
            `Quick test_a_cancelled_run_pool_passes_the_cancellation_on;
          Alcotest.test_case "a connection that keeps no statements reads text"
            `Quick test_a_connection_that_keeps_no_statements_reads_text;
          Alcotest.test_case "a bound is whole milliseconds, rounded up" `Quick
            test_a_bound_is_whole_milliseconds_rounded_up;
          Alcotest.test_case "an instant reads back to the millisecond" `Quick
            test_an_instant_reads_back_to_the_millisecond;
          Alcotest.test_case "a statement is a span" `Quick
            test_a_statement_is_a_span;
          Alcotest.test_case "a pool is measured" `Quick test_a_pool_is_measured;
          Alcotest.test_case "a pool says how it stands" `Quick
            test_a_pool_says_how_it_stands;
          Alcotest.test_case "a busy pool is ready" `Quick
            test_a_busy_pool_is_ready;
          Alcotest.test_case "a closed pool is not ready" `Quick
            test_a_closed_pool_is_not_ready;
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
          Alcotest.test_case "a deferred conflict answers as a statement's does"
            `Quick test_a_deferred_conflict_answers_as_a_statement's_does;
        ] );
      ( "sessions",
        [
          Alcotest.test_case "the installed migration is the schema" `Quick
            test_the_installed_migration_is_the_schema;
          Alcotest.test_case "sessions are kept in a table" `Quick
            test_sessions_are_kept_in_a_table;
          Alcotest.test_case "sessions read the pool as a resource" `Quick
            test_sessions_read_the_pool_as_a_resource;
          Alcotest.test_case "a store's table is checked where it is made"
            `Quick test_a_stores_table_is_checked_where_it_is_made;
          Alcotest.test_case "a reserved word is a table's name" `Quick
            test_a_reserved_word_is_a_table's_name;
          Alcotest.test_case "the longest name is a table's name" `Quick
            test_the_longest_name_is_a_table's_name;
          Alcotest.test_case "a store's busy pool reads as the pool's words"
            `Quick test_a_stores_busy_pool_reads_as_the_pools_words;
        ] );
      ( "errors",
        [
          Alcotest.test_case "every failure has its words" `Quick
            test_every_failure_has_its_words;
          Alcotest.test_case "an unreachable database answers busy" `Quick
            test_an_unreachable_database_answers_busy;
        ] );
      ( "logs",
        [
          Alcotest.test_case "the log source is the library's name" `Quick
            test_the_log_source_is_the_librarys_name;
        ] );
    ]
