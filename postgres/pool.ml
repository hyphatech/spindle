module Pg = Rowtype_postgres

type t = Pg.Pool.t

let create ~sw ~net ~mono_clock:clock ?size ?wait_s ?statement_timeout_ms
    ?idle_in_transaction_timeout_ms ?connect_timeout_s ?parameters ?timeout_s
    ?statement_cache ?reset ?max_lifetime_s ?idle_check_s target =
  Result.bind
    (Bounds.apply ?statement_timeout_ms ?idle_in_transaction_timeout_ms
       ?connect_timeout_s ?parameters target) (fun (c, parameters) ->
      Pg.Pool.create ~sw ~net ~mono_clock:clock ~parameters
        ~observe:Traced.observer ?timeout_s ?statement_cache ?size ?wait_s
        ?reset ?max_lifetime_s ?idle_check_s c)

module L = (val Logs.src_log Source.src : Logs.LOG)

let use ?wait_s t work =
  match Pg.Pool.use ?wait_s t work with
  | Ok answer -> answer
  | Error `Busy -> Error `Busy

let query ?wait_s t statement args =
  use ?wait_s t (fun db -> Pg.run db statement args)

type stats = Pg.Pool.stats = {
  size : int;
  idle : int;
  waiting : int;
  replaced : int;
}

let stats = Pg.Pool.stats

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
   that a probe every few seconds would fill the log with. *)
let check ?(name = "postgres") t =
  Spindle.Health.check name (fun () ->
      if (stats t).idle = 0 then Ok ()
      else
        match use t (fun db -> Pg.exec_raw db "select 1") with
        | Ok () -> Ok ()
        | Error `Busy -> Ok ()
        | Error (#Rowtype.error as e) -> Error (Rowtype.error_to_string e))

let transaction ?wait_s ?keep ?isolation ?retries t work =
  use ?wait_s t (fun db ->
      Rowtype_postgres.Transaction.within ?keep ?isolation ?retries db work)

let close = Pg.Pool.close

(* Closed when [f] returns, so idle connections end properly. A database that
   refuses ends the program, saying why. *)
let run ?size ?wait_s ?statement_timeout_ms ?idle_in_transaction_timeout_ms
    ?connect_timeout_s ?parameters ?timeout_s ?statement_cache ?reset
    ?max_lifetime_s ?idle_check_s env target f =
  Eio.Switch.run @@ fun sw ->
  match
    create ~sw ~net:(Eio.Stdenv.net env)
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ?size ?wait_s ?statement_timeout_ms ?idle_in_transaction_timeout_ms
      ?connect_timeout_s ?parameters ?timeout_s ?statement_cache ?reset
      ?max_lifetime_s ?idle_check_s target
  with
  | Ok pool -> Fun.protect ~finally:(fun () -> close pool) (fun () -> f pool)
  | Error e ->
      L.err (fun m ->
          m "the pool could not be opened: %s" (Rowtype.error_to_string e));
      exit 1
