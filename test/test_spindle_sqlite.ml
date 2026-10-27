(* The SQLite kit against SQLite itself: a file of each case's own, which
   needs no server. *)

module S = Rowtype
module Sq = Rowtype_sqlite

let ok = function
  | Ok v -> v
  | Error e -> Alcotest.failf "unexpected error: %s" (S.error_to_string e)

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || go (i + 1))
  in
  go 0

(* A file no other case shares, and what SQLite keeps beside it, gone
   after. *)
let with_file f =
  let file = Filename.temp_file "spindle_sqlite" ".db" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun suffix ->
          match Sys.remove (file ^ suffix) with
          | () -> ()
          | exception Sys_error _ -> ())
        [ ""; "-journal"; "-wal"; "-shm" ])
    (fun () -> f file)

let on_pool ?(size = 1) ?(wait = Mtime.Span.(2 * s)) ?timeout f =
  with_file @@ fun file ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool =
    ok
      (Spindle_sqlite.Pool.create ~sw
         ~mono_clock:(Eio.Stdenv.mono_clock env)
         ~size ~wait ?timeout file)
  in
  f env file pool

let db : Spindle_sqlite.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

(* Work on one borrowed connection, which a pool at rest always lends. *)
let on_connection pool work =
  match Spindle_sqlite.Pool.use pool work with
  | Ok v -> v
  | Error (`Pool _) -> Alcotest.fail "a pool at rest lent nothing"
  | Error (#S.error as e) -> Alcotest.fail (S.error_to_string e)

let exec pool statement args =
  on_connection pool (fun c -> Sq.run c statement args)

let status refusal = Spindle_http.Status.to_int (Spindle.Refusal.status refusal)

let instant s =
  match Ptime.of_float_s s with
  | Some t -> t
  | None -> Alcotest.failf "%f is no instant" s

let instant_t = Alcotest.testable Ptime.pp Ptime.equal

(* ------------------------------------------------------------------ *)
(* Failures *)

let test_every_failure_has_its_words () =
  let told what expected e =
    Alcotest.(check string) what expected (Spindle_sqlite.error_to_string e)
  in
  List.iter
    (fun e -> told "a statement's failure" (S.error_to_string e) e)
    [
      `Conflict (Some "users.email");
      `Not_serializable "database is locked";
      `Db "no such table: users";
    ];
  told "busy" (Rowtype_sqlite.error_to_string (`Pool `Busy)) (`Pool `Busy);
  told "pool closed"
    (Rowtype_sqlite.error_to_string (`Pool `Closed))
    (`Pool `Closed)

(* What asking again may get past is 503; what is a bug is 500. *)
let test_each_failure_has_its_answer () =
  List.iter
    (fun (what, expected, e) ->
      Alcotest.(check int) what expected (status (Spindle_sqlite.refusal e)))
    [
      ("a busy pool", 503, `Pool `Busy);
      ("a closed pool", 503, `Pool `Closed);
      ("a lock held past the wait", 503, `Not_serializable "database is locked");
      ("a conflict nobody matched", 500, `Conflict (Some "users.email"));
      ("anything else", 500, `Db "no such table: users");
      ("a transaction not committed", 500, `Not_committed "commit");
    ]

(* A user filters a library's log by the name they installed. *)
let test_the_log_source_is_the_librarys_name () =
  Alcotest.(check bool)
    "spindle-sqlite is a source" true
    (List.exists
       (fun src -> String.equal (Logs.Src.name src) "spindle-sqlite")
       (Logs.Src.list ()))

(* ------------------------------------------------------------------ *)
(* The pool *)

(* Readers go on beside a writer only in WAL mode, which the file keeps
   once the pool has set it. *)
let test_a_pool_puts_its_file_in_wal_mode () =
  on_pool @@ fun env file pool ->
  Spindle_sqlite.Pool.close pool;
  Eio.Switch.run @@ fun sw ->
  let c = ok (Sq.connect ~sw ~mono_clock:(Eio.Stdenv.mono_clock env) file) in
  Alcotest.(check string)
    "the file's journal" "wal"
    (ok (Sq.run c (S.find ~params:S.unit ~row:S.text "pragma journal_mode") ()))

(* Each connection would have a database of its own. *)
let test_a_database_in_memory_is_refused () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match
    Spindle_sqlite.Pool.create ~sw
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ":memory:"
  with
  | Ok _ -> Alcotest.fail "a pool in memory was made"
  | Error _ -> ()

let test_a_held_pool_is_busy () =
  on_pool ~wait:Mtime.Span.(10 * ms) @@ fun _ _ pool ->
  let inner =
    Spindle_sqlite.Pool.use pool (fun _ ->
        Ok (Spindle_sqlite.Pool.exec pool (S.exec ~params:S.unit "select 1") ()))
  in
  (match inner with
  | Ok (Error (`Pool `Busy)) -> ()
  | _ -> Alcotest.fail "a second borrow of a pool of one was lent");
  exec pool (S.exec ~params:S.unit "select 1") ()

let test_a_run_pool_is_closed_after () =
  with_file @@ fun file ->
  Eio_main.run @@ fun env ->
  let answer, pool =
    Spindle_sqlite.Pool.run env file ~size:2 (fun pool ->
        ( Spindle_sqlite.Pool.exec pool
            (S.find ~params:S.unit ~row:S.int "select 1")
            (),
          pool ))
  in
  (match answer with Ok 1 -> () | _ -> Alcotest.fail "the pool was not lent");
  Alcotest.(check int)
    "nothing idle once closed" 0 (Spindle_sqlite.Pool.stats pool).idle

let test_a_pool_says_how_it_stands () =
  on_pool ~size:2 @@ fun _ _ pool ->
  match
    Spindle_sqlite.Pool.use pool (fun _ -> Ok (Spindle_sqlite.Pool.stats pool))
  with
  | Error (`Pool _) -> Alcotest.fail "busy with nothing borrowed"
  | Ok (held : Spindle_sqlite.Pool.stats) ->
      Alcotest.(check (list int))
        "size, idle and waiting while one is borrowed" [ 2; 1; 0 ]
        [ held.size; held.idle; held.waiting ];
      Alcotest.(check int)
        "idle once it is back" 2 (Spindle_sqlite.Pool.stats pool).idle

let test_a_pool_is_measured () =
  on_pool ~size:2 @@ fun _ _ pool ->
  let metrics = Spindle.Metrics.create () in
  Spindle_sqlite.Pool.measure pool metrics;
  match
    Spindle_sqlite.Pool.use pool (fun _ ->
        Ok (Spindle.Metrics.exposition metrics))
  with
  | Error (`Pool _) -> Alcotest.fail "busy with nothing borrowed"
  | Ok text ->
      List.iter
        (fun line -> Alcotest.(check bool) line true (contains ~sub:line text))
        [
          {|db_client_connection_count{db_client_connection_pool_name="sqlite",db_client_connection_state="idle"} 1|};
          {|db_client_connection_count{db_client_connection_pool_name="sqlite",db_client_connection_state="used"} 1|};
          {|db_client_connection_pending_requests{db_client_connection_pool_name="sqlite"} 0|};
        ]

(* Ready at rest and while every connection is lent; not once closed. *)
let test_a_pool_is_a_readiness_check () =
  on_pool @@ fun _ _ pool ->
  let app =
    Spindle.Test.app
      ~resources:[ Spindle.Dep.resource db pool ]
      (Spindle.Health.routes [ Spindle_sqlite.Pool.check db ])
  in
  let ready () =
    Spindle_http.Status.to_int (Spindle.Test.call app `GET "/readyz").status
  in
  Alcotest.(check int) "at rest" 200 (ready ());
  let held = ref 0 in
  ignore
    (Spindle_sqlite.Pool.use pool (fun _ -> Ok (held := ready ()))
      : (unit, _) result);
  Alcotest.(check int) "while every connection is lent" 200 !held;
  Spindle_sqlite.Pool.close pool;
  Alcotest.(check int) "once closed" 503 (ready ())

(* ------------------------------------------------------------------ *)
(* Transactions *)

let count pool =
  exec pool (S.find ~params:S.unit ~row:S.int "select count(*) from t") ()

let insert = S.exec ~params:S.int "insert into t values ($1)"

let test_a_transaction_is_all_or_nothing () =
  on_pool @@ fun _ _ pool ->
  exec pool (S.exec ~params:S.unit "create table t (n integer primary key)") ();
  let ( let* ) = Result.bind in
  (match
     Spindle_sqlite.Pool.transaction ~behaviour:Immediate pool (fun db ->
         let* () = Sq.run db insert 1 in
         Sq.run db insert 2)
   with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "the transaction failed");
  Alcotest.(check int) "both kept" 2 (count pool);
  (match
     Spindle_sqlite.Pool.transaction pool (fun db ->
         let* () = Sq.run db insert 3 in
         Sq.run db insert 1)
   with
  | Error (`Conflict _) -> ()
  | _ -> Alcotest.fail "a duplicate key was kept");
  Alcotest.(check int) "neither of the second" 2 (count pool)

(* SQLite has one writer: a write waiting past its lock's wait is
   [`Not_serializable], which asking again may get past. *)
let test_a_lock_held_past_the_wait_answers_busy () =
  on_pool ~size:2 ~timeout:Mtime.Span.(10 * ms) @@ fun _ _ pool ->
  exec pool (S.exec ~params:S.unit "create table t (n integer)") ();
  let blocked =
    Spindle_sqlite.Pool.transaction ~behaviour:Immediate pool (fun _ ->
        Ok (Spindle_sqlite.Pool.exec pool insert 1))
  in
  match blocked with
  | Ok (Error e) ->
      Alcotest.(check int) "503" 503 (status (Spindle_sqlite.refusal e))
  | Ok (Ok ()) -> Alcotest.fail "written under another's lock"
  | Error _ -> Alcotest.fail "the holding transaction failed"

(* A statement run in a kept trace is a span of it, with its text and
   never its parameters. *)
let test_a_statement_is_a_span () =
  on_pool @@ fun env _ pool ->
  let spans = ref [] in
  let trace =
    Spindle.Trace.exporter ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) (fun sp -> spans := sp :: !spans)
  in
  let answer =
    Spindle.Log.with_request_id ~trace "r-1" (fun () ->
        Spindle_sqlite.Pool.exec pool
          (S.find ~params:S.text ~row:S.int "select length($1)")
          "hunter2")
  in
  (match answer with
  | Ok n -> Alcotest.(check int) "the statement's answer" 7 n
  | Error _ -> Alcotest.fail "the statement failed");
  match List.rev !spans with
  | [ select; request ] ->
      Alcotest.(check bool)
        "a client span of the request's, named sqlite" true
        (String.equal select.name "sqlite"
        && select.kind = Spindle.Trace.Client
        && select.parent_id = Some request.span_id);
      Alcotest.(check bool)
        "its text, and no parameter" true
        (List.mem
           ("db.query.text", `String "select length($1)")
           select.attributes
        && not
             (List.exists
                (fun (_, v) ->
                  match v with
                  | `String v -> String.equal v "hunter2"
                  | `Int _ | `Float _ | `Bool _ -> false)
                select.attributes))
  | l -> Alcotest.failf "expected two spans, got %d" (List.length l)

(* ------------------------------------------------------------------ *)
(* Sessions *)

let read path = In_channel.with_open_bin path In_channel.input_all

let migration =
  "../sqlite/migrations/20261021000000_create_spindle_sessions.sql"

(* The migration the package installs is written from the schema, and
   held to it. *)
let test_the_installed_migration_is_the_schema () =
  let text = read migration in
  Alcotest.(check bool)
    "it ends in the schema of the default table" true
    (String.ends_with
       ~suffix:
         (Spindle_sqlite.Session.schema
            ~table:Spindle_sqlite.Session.default_table)
       text)

let store_of pool ?table () =
  let open Spindle.Syntax in
  let read = Spindle_sqlite.Session.store ?table db and kept = ref None in
  let app =
    Spindle.Test.app
      ~resources:[ Spindle.Dep.resource db pool ]
      [
        Spindle.Access.public
        @@ Spindle.get Spindle.Path.root Spindle.Returns.text
             (let+ store = read in
              kept := Some store;
              Ok "kept");
      ]
  in
  ignore (Spindle.Test.call app `GET "/");
  match !kept with Some store -> store | None -> Alcotest.fail "no store"

let entry ?(seen = 2.) expires =
  {
    Spindle.Session.data = {|"kim"|};
    created = instant 1.;
    seen = instant seen;
    expires = instant expires;
  }

let got = function Ok v -> v | Error m -> Alcotest.fail m

(* The installed migration makes the table, and every statement the store
   runs is one SQLite agrees with. *)
let test_sessions_are_kept_in_a_table () =
  on_pool @@ fun _ _ pool ->
  on_connection pool (fun c ->
      Result.bind
        (Sq.exec_raw c (read migration))
        (fun () ->
          match Sq.verify c (Spindle_sqlite.Session.statements ()) with
          | Ok () -> Ok ()
          | Error (`Disagreements ms) -> Alcotest.fail (String.concat "; " ms)
          | Error (#S.error as e) -> Error e));
  let store = store_of pool () in
  got (store.save "d1" (entry 10.));
  got (store.save "d2" (entry 5.));
  (match got (store.find "d1") with
  | Some e ->
      Alcotest.(check string) "its data" {|"kim"|} e.data;
      Alcotest.check instant_t "its instants" (instant 10.) e.expires
  | None -> Alcotest.fail "the session was not kept");
  got (store.save "d1" (entry ~seen:3. 20.));
  Alcotest.(check (option instant_t))
    "a save replaces"
    (Some (instant 3.))
    (Option.map
       (fun (e : Spindle.Session.entry) -> e.seen)
       (got (store.find "d1")));
  got (store.save "d3" (entry 4.));
  Alcotest.(check int)
    "a sweep stops at its limit" 1
    (got (store.sweep ~now:(instant 6.) ~limit:1));
  Alcotest.(check bool)
    "having taken the soonest ended" true
    (Option.is_none (got (store.find "d3"))
    && Option.is_some (got (store.find "d2")));
  got (store.delete "d1");
  Alcotest.(check bool)
    "and a delete, what it names" true
    (Option.is_none (got (store.find "d1")))

(* A table of the application's own, made from the schema, and named with
   a word SQL reserves. *)
let test_a_table_of_its_own () =
  on_pool @@ fun _ _ pool ->
  on_connection pool (fun c ->
      Sq.exec_raw c (Spindle_sqlite.Session.schema ~table:"user"));
  let store = store_of pool ~table:"user" () in
  got (store.save "d1" (entry 10.));
  Alcotest.(check (option string))
    "kept in it" (Some {|"kim"|})
    (Option.map
       (fun (e : Spindle.Session.entry) -> e.data)
       (got (store.find "d1")))

(* A table's name is a constant written in source, refused where the store
   is made, never as a request's 500. *)
let test_a_stores_table_is_checked_where_it_is_made () =
  Alcotest.(check bool)
    "refused at once" true
    (match Spindle_sqlite.Session.store ~table:"x; drop" db with
    | _ -> false
    | exception Invalid_argument _ -> true)

(* Sessions read the pool as every route does. *)
let test_sessions_read_the_pool_as_a_resource () =
  on_pool @@ fun _ _ pool ->
  let open Spindle.Syntax in
  on_connection pool (fun c -> Sq.exec_raw c (read migration));
  let session =
    Spindle.Session.create
      ~store:(Spindle_sqlite.Session.store db)
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
  let b =
    Spindle.Test.browser
      (Spindle.Test.app
         ~resources:[ Spindle.Dep.resource db pool ]
         (List.map Spindle.Access.public routes))
  in
  ignore (Spindle.Test.Browser.call b `POST "/sign-in");
  Alcotest.(check string)
    "found in the table" "kim" (Spindle.Test.Browser.call b `GET "/me").body

let () =
  Alcotest.run "spindle-sqlite"
    [
      ( "failures",
        [
          Alcotest.test_case "every failure has its words" `Quick
            test_every_failure_has_its_words;
          Alcotest.test_case "each failure has its answer" `Quick
            test_each_failure_has_its_answer;
          Alcotest.test_case "the log source is the library's name" `Quick
            test_the_log_source_is_the_librarys_name;
        ] );
      ( "the pool",
        [
          Alcotest.test_case "its file in WAL mode" `Quick
            test_a_pool_puts_its_file_in_wal_mode;
          Alcotest.test_case "no database in memory" `Quick
            test_a_database_in_memory_is_refused;
          Alcotest.test_case "a held pool is busy" `Quick
            test_a_held_pool_is_busy;
          Alcotest.test_case "a run pool is closed after" `Quick
            test_a_run_pool_is_closed_after;
          Alcotest.test_case "it says how it stands" `Quick
            test_a_pool_says_how_it_stands;
          Alcotest.test_case "it is measured" `Quick test_a_pool_is_measured;
          Alcotest.test_case "it is a readiness check" `Quick
            test_a_pool_is_a_readiness_check;
        ] );
      ( "transactions",
        [
          Alcotest.test_case "all or nothing" `Quick
            test_a_transaction_is_all_or_nothing;
          Alcotest.test_case "a lock held past the wait" `Quick
            test_a_lock_held_past_the_wait_answers_busy;
          Alcotest.test_case "a statement is a span" `Quick
            test_a_statement_is_a_span;
        ] );
      ( "sessions",
        [
          Alcotest.test_case "the installed migration is the schema" `Quick
            test_the_installed_migration_is_the_schema;
          Alcotest.test_case "kept in a table" `Quick
            test_sessions_are_kept_in_a_table;
          Alcotest.test_case "a table of its own" `Quick test_a_table_of_its_own;
          Alcotest.test_case "the table checked where the store is made" `Quick
            test_a_stores_table_is_checked_where_it_is_made;
          Alcotest.test_case "read through the pool" `Quick
            test_sessions_read_the_pool_as_a_resource;
        ] );
    ]
