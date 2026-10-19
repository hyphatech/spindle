module Pg = Rowtype_postgres

(* Whether it was closed is kept here for [check], which borrows only
   while a connection is idle: a closed pool has none, as a busy one has
   none, and its stats do not say which. *)
type t = { pool : Pg.Pool.t; closed : bool Atomic.t }

let create ~sw ~net ~mono_clock:clock ?size ?wait ?statement_timeout
    ?idle_in_transaction_timeout ?parameters ?timeout ?statement_cache ?reset
    ?max_lifetime ?idle_check target =
  let c, parameters =
    Bounds.apply ?statement_timeout ?idle_in_transaction_timeout ?parameters
      target
  in
  Result.map
    (fun pool -> { pool; closed = Atomic.make false })
    (Pg.Pool.create ~sw ~net ~mono_clock:clock ~parameters
       ~observe:Traced.observer ?timeout ?statement_cache ?size ?wait ?reset
       ?max_lifetime ?idle_check c)

module L = (val Logs.src_log Source.src : Logs.LOG)

let use ?wait t work = Result.join (Pg.Pool.use ?wait t.pool work)

let exec ?wait t statement args =
  use ?wait t (fun db -> Pg.run db statement args)

type stats = Pg.Pool.stats = {
  size : int;
  idle : int;
  waiting : int;
  replaced : int;
}

let stats t = Pg.Pool.stats t.pool

(* Sampled when the metrics are read: [stats] already holds what is known. *)
let measure ?(name = "postgres") t metrics =
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
let check ?(name = "postgres") db =
  Spindle.Health.check name
    (Spindle.Dep.map
       (fun t () ->
         if Atomic.get t.closed then Error "the pool is closed"
         else if (stats t).idle = 0 then Ok ()
         else
           match use t (fun db -> Pg.exec_raw db "select 1") with
           | Ok () -> Ok ()
           | Error (`Pool `Busy) -> Ok ()
           | Error (`Pool `Closed as e) -> Error (Pg.error_to_string e)
           | Error (#Rowtype.error as e) -> Error (Rowtype.error_to_string e))
       db)

let transaction ?wait ?keep ?isolation ?retries t work =
  use ?wait t (fun db ->
      Rowtype_postgres.Transaction.within ?keep ?isolation ?retries db work)

let close t =
  Atomic.set t.closed true;
  Pg.Pool.close t.pool

(* Closed when [f] returns or raises, so idle connections end properly. A
   cancelled [f] is not closed after: closing waits to tell the server, which
   a cancelled fiber cannot, and would raise its cancellation as
   [Fun.Finally_raised]. Its connections end with the switch. A database that
   refuses ends the program, saying why. *)
let run ?size ?wait ?statement_timeout ?idle_in_transaction_timeout ?parameters
    ?timeout ?statement_cache ?reset ?max_lifetime ?idle_check env target f =
  Eio.Switch.run @@ fun sw ->
  match
    Result.bind
      (Result.map_error
         (fun m -> "a connection string that does not parse: " ^ m)
         (Pg.Conninfo.of_string target))
      (fun target ->
        Result.map_error Rowtype.error_to_string
          (create ~sw ~net:(Eio.Stdenv.net env)
             ~mono_clock:(Eio.Stdenv.mono_clock env)
             ?size ?wait ?statement_timeout ?idle_in_transaction_timeout
             ?parameters ?timeout ?statement_cache ?reset ?max_lifetime
             ?idle_check target))
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
  | Error m ->
      L.err (fun f -> f "the pool could not be opened: %s" m);
      exit 1
