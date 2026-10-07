(* Where a test's database comes from.

   Every suite that touches a database needs a Postgres server, and names it
   with SPINDLE_TEST_PG -- which `make test` sets after bringing the tests'
   own container up. A bare `dune test` leaves it unset, and those suites
   then skip themselves and SAY so, rather than failing on a machine with
   no Docker or passing without having run. {!required} is that seam. *)

let base = Sys.getenv_opt "SPINDLE_TEST_PG"

(* Called first by every suite that needs a database. Without one it prints
   why and exits cleanly, so a skipped suite is a line in the output and not
   a silent green. *)
let required ~suite =
  if Option.is_none base then begin
    Printf.printf
      "  [%s skipped: no SPINDLE_TEST_PG -- set it to a Postgres server's URL]\n\
       %!"
      suite;
    exit 0
  end

(* The Eio loop a suite runs its cases in, and a switch that lasts as long:
   a connection is Eio's, and a suite's cases are functions of nothing, so
   the one [Eio_main.run] a suite starts in hands both over once, with
   [eio env ~sw]. *)
let loop : (Eio_unix.Stdenv.base * Eio.Switch.t) option ref = ref None
let eio env ~sw = loop := Some ((env :> Eio_unix.Stdenv.base), sw)

let io () =
  match !loop with
  | Some v -> v
  | None -> Alcotest.fail "the suite did not call Db_target.eio env ~sw"

let sw () = snd (io ())
let net () = Eio.Stdenv.net (fst (io ()))
let mono () = Eio.Stdenv.mono_clock (fst (io ()))

let server () =
  match base with
  | None -> Alcotest.fail "SPINDLE_TEST_PG is not set"
  | Some server -> server

(* The server a URL names, with the database path replaced. *)
let on_database name =
  match Rowtype_postgres.on_database ~server:(server ()) name with
  | Ok url -> url
  | Error e -> Alcotest.failf "SPINDLE_TEST_PG: %s" (Rowtype.error_to_string e)

let connect url =
  match
    Spindle_postgres.connect ~sw:(sw ()) ~net:(net ()) ~mono_clock:(mono ()) url
  with
  | Ok db -> db
  | Error e -> Alcotest.failf "cannot connect: %s" (Rowtype.error_to_string e)

let admin f =
  let db = connect (server ()) in
  Fun.protect ~finally:(fun () -> Rowtype_postgres.close db) (fun () -> f db)

let exec db sql =
  match Rowtype_postgres.exec_raw db sql with
  | Ok () -> ()
  | Error e -> Alcotest.failf "%s: %s" sql (Rowtype.error_to_string e)

(* A database of its own per asking, so one case cannot see another's rows
   and a failure leaves nothing behind for the next run to trip over. The
   name carries the pid because `dune test` runs the executables in
   parallel, and a counter because one executable asks many times.

   [with (force)] because a connection the test failed to close would
   otherwise make the drop fail and leave the database behind -- and a
   leaked database is a slow leak nobody notices until the container is
   full. *)
let nth = ref 0

let with_postgres f =
  incr nth;
  let name = Printf.sprintf "spindle_test_%d_%d" (Unix.getpid ()) !nth in
  admin (fun db -> exec db (Printf.sprintf "create database %s" name));
  let finally () =
    admin (fun db ->
        exec db (Printf.sprintf "drop database if exists %s with (force)" name))
  in
  Fun.protect ~finally (fun () -> f (on_database name))
