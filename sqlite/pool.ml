module Sq = Rowtype_sqlite

(* Whether it was closed is kept here for [check], which borrows only
   while a connection is idle: a closed pool has none, as a busy one has
   none, and its stats do not say which. *)
type t = { pool : Sq.Pool.t; closed : bool Atomic.t }

module L = (val Logs.src_log Source.src : Logs.LOG)

let use ?wait t work = Result.join (Sq.Pool.use ?wait t.pool work)

(* WAL is the file's, kept by it once set, so readers go on beside a writer
   rather than wait for its COMMIT; set from the first connection, before
   any is lent. *)
let create ~sw ~mono_clock ?size ?wait ?timeout file =
  match
    Sq.Pool.create ~sw ~mono_clock ~observe:Traced.observer ?timeout ?size ?wait
      file
  with
  | Error e -> Error e
  | Ok pool -> (
      let t = { pool; closed = Atomic.make false } in
      match use t (fun db -> Sq.exec_raw db "pragma journal_mode = wal") with
      | Ok () -> Ok t
      | Error (`Pool _) ->
          Sq.Pool.close pool;
          Error (`Db "the pool lent no connection to set WAL mode on")
      | Error (#Rowtype.error as e) ->
          Sq.Pool.close pool;
          Error e)

let exec ?wait t statement args =
  use ?wait t (fun db -> Sq.run db statement args)

type stats = Sq.Pool.stats = { size : int; idle : int; waiting : int }

let stats t = Sq.Pool.stats t.pool

(* Sampled when the metrics are read: [stats] already holds what is known. *)
let measure ?(name = "sqlite") t metrics =
  let pool = "db.client.connection.pool.name" in
  Spindle.Metrics.sampled metrics ~help:"Connections the pool holds, by state"
    ~labels:[ pool; "db.client.connection.state" ] "db.client.connection.count"
    (fun () ->
      let s = stats t in
      [
        ([ name; "idle" ], float_of_int s.idle);
        ([ name; "used" ], float_of_int (s.size - s.idle));
      ]);
  Spindle.Metrics.sampled metrics ~help:"Borrows waiting for a connection"
    ~labels:[ pool ] "db.client.connection.pending_requests" (fun () ->
      [ ([ name ], float_of_int (stats t).waiting) ])

(* A busy pool is not borrowed from: the wait could end empty, a warning
   that a probe every few seconds would fill the log with. A closed one has
   nothing idle either, and is told apart first. *)
let check ?(name = "sqlite") db =
  Spindle.Health.check name
    (Spindle.Dep.map
       (fun t () ->
         if Atomic.get t.closed then Error "the pool is closed"
         else if (stats t).idle = 0 then Ok ()
         else
           match use t (fun db -> Sq.exec_raw db "select 1") with
           | Ok () -> Ok ()
           | Error (`Pool `Busy) -> Ok ()
           | Error (`Pool `Closed as e) -> Error (Sq.error_to_string e)
           | Error (#Rowtype.error as e) -> Error (Rowtype.error_to_string e))
       db)

let transaction ?wait ?keep ?behaviour ?retries t work =
  use ?wait t (fun db ->
      Sq.Transaction.within ?keep ?behaviour ?retries db work)

let close t =
  Atomic.set t.closed true;
  Sq.Pool.close t.pool

(* Closed when [f] returns or raises. A cancelled [f] is not closed after:
   its connections end with the switch, and a cancellation raised from a
   [finally] would be [Fun.Finally_raised]. A database that cannot be
   opened ends the program, saying why. *)
let run ?size ?wait ?timeout env file f =
  Eio.Switch.run @@ fun sw ->
  match
    create ~sw ~mono_clock:(Eio.Stdenv.mono_clock env) ?size ?wait ?timeout file
  with
  | Ok pool -> (
      match f pool with
      | v ->
          close pool;
          v
      | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
      | exception ex ->
          let bt = Printexc.get_raw_backtrace () in
          close pool;
          Printexc.raise_with_backtrace ex bt)
  | Error e ->
      L.err (fun f ->
          f "the pool could not be opened: %s" (Rowtype.error_to_string e));
      exit 1
