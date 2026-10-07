(** Connections, made up front and borrowed one at a time: the Postgres
    backend's pool ([Rowtype_postgres.Pool]), each connection bounded as
    {!Spindle_postgres.connect} bounds one, and a transaction on a borrow. *)

type t

val create :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  ?size:int ->
  ?wait_s:float ->
  ?statement_timeout_ms:int ->
  ?idle_in_transaction_timeout_ms:int ->
  ?connect_timeout_s:int ->
  ?parameters:(string * string) list ->
  ?timeout_s:float ->
  ?statement_cache:int ->
  ?reset:bool ->
  ?max_lifetime_s:float ->
  ?idle_check_s:float ->
  string ->
  (t, [> Rowtype.error ]) result
(** The pool [Rowtype_postgres.Pool.create] makes, to the database the
    connection string names, every option but the bounds passed through. The
    bounds and [parameters] are {!Spindle_postgres.connect}'s. *)

val use :
  ?wait_s:float ->
  t ->
  (Rowtype_postgres.conn -> ('a, ([> `Busy ] as 'e)) result) ->
  ('a, 'e) result
(** Borrow a connection for [work], as [Rowtype_postgres.Pool.use] lends one,
    and give it back when [work] returns. [`Busy] -- no connection within the
    wait -- joins the work's own failures, so that an overloaded server says so
    instead of answering late; {!Spindle_postgres.refusal} words it. *)

val query :
  ?wait_s:float ->
  t ->
  ('p, 'r) Rowtype.statement ->
  'p ->
  ('r, [> `Busy | Rowtype.error ]) result
(** One statement on a borrowed connection: {!use} around
    [Rowtype_postgres.run], for the read that is the whole of its work.

    {[
    Spindle_postgres.Pool.query pool all_users ()
    |> Result.map_error Spindle_postgres.refusal
    ]} *)

val transaction :
  ?wait_s:float ->
  ?keep:('e -> bool) ->
  ?isolation:Rowtype_postgres.Transaction.isolation ->
  ?retries:int ->
  t ->
  (Rowtype_postgres.conn ->
  ('a, ([> Rowtype_postgres.Transaction.failure | `Busy ] as 'e)) result) ->
  ('a, 'e) result
(** {!use} and [Rowtype_postgres.Transaction.within] together: borrow a
    connection and run one transaction on it, at [isolation] and run again up to
    [retries] times, [Ok] committing and [Error] rolling back unless [keep] says
    otherwise. A retry keeps the connection it borrowed. Every failure of its
    own -- no connection within the wait, a transaction that did not commit --
    arrives in the caller's error type:

    {[
    Spindle_postgres.Pool.transaction pool (fun db ->
        let* id = Pg.run db add_user (name, email) in
        let* () = Pg.run db log_event (id, "signed_up") in
        Ok id)
    ]} *)

type stats = Rowtype_postgres.Pool.stats = {
  size : int;
  idle : int;
  waiting : int;
  replaced : int;
}

val stats : t -> stats
(** As [Rowtype_postgres.Pool.stats]. *)

val measure : ?name:string -> t -> Spindle.Metrics.t -> unit
(** The pool's connections as gauges, read from {!val-stats} whenever the
    metrics are, so the pool keeps no count of its own: OpenTelemetry's
    [db.client.connection.count] by [db.client.connection.state], [idle] or
    [used], and [db.client.connection.pending_requests], the borrows waiting --
    each under [db.client.connection.pool.name], [postgres] unless named, so two
    pools measured on one registry are two series of each.

    {[
    Spindle_postgres.Pool.measure pool metrics
    ]} *)

val check : ?name:string -> t -> Spindle.Health.check
(** The pool as a readiness check, [postgres] unless named: a connection
    borrowed and [select 1] answered, within the pool's wait and the statement
    timeout. A pool with no connection idle passes without a borrow, since every
    one of them is lent to a request the database is answering -- failing it
    would take a server out of service for being busy, which is when it is
    needed most. *)

val close : t -> unit
(** As [Rowtype_postgres.Pool.close]. *)

val run :
  ?size:int ->
  ?wait_s:float ->
  ?statement_timeout_ms:int ->
  ?idle_in_transaction_timeout_ms:int ->
  ?connect_timeout_s:int ->
  ?parameters:(string * string) list ->
  ?timeout_s:float ->
  ?statement_cache:int ->
  ?reset:bool ->
  ?max_lifetime_s:float ->
  ?idle_check_s:float ->
  < net : _ Eio.Net.t ; mono_clock : _ Eio.Time.Mono.t ; .. > ->
  string ->
  (t -> 'a) ->
  'a
(** [run env target f] is a program's pool: {!create}d on a switch of its own,
    with the network and the monotonic clock taken from [env], handed to [f],
    and {!close}d when [f] returns or raises --

    {[
    Eio_main.run @@ fun env ->
    Spindle_postgres.Pool.run env target @@ fun pool ->
    Spindle.serve env (routes pool)
    ]}

    Every option is {!create}'s. A pool that cannot be opened -- a database that
    refuses, a connection string that does not parse -- is an [error] line on
    [spindle.postgres] saying why, and the program exits with status 1, because
    a server that cannot reach its database has nothing to serve. A program that
    would rather go on without one calls {!create}. *)
