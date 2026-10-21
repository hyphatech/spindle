(** Connections to one SQLite file, made up front and borrowed one at a time:
    the SQLite backend's pool ([Rowtype_sqlite.Pool]), the file in WAL mode, and
    a transaction on a borrow. *)

type t

val create :
  sw:Eio.Switch.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  ?size:int ->
  ?wait:Mtime.Span.t ->
  ?timeout:Mtime.Span.t ->
  string ->
  (t, [> Rowtype.error ]) result
(** The pool [Rowtype_sqlite.Pool.create] makes, to the database [file] names,
    made where there is none, every option passed through: [timeout] is how long
    a statement waits for another connection's lock, 5 s unless given. The file
    is put in WAL mode, which it keeps, so readers go on beside a writer and
    never wait on one; a pool whose file cannot be is the failure, and closed. A
    database in memory is refused, since each connection would have one of its
    own. *)

val use :
  ?wait:Mtime.Span.t ->
  t ->
  (Rowtype_sqlite.conn ->
  ('a, ([> `Pool of [ `Busy | `Closed ] ] as 'e)) result) ->
  ('a, 'e) result
(** Borrow a connection for [work], as [Rowtype_sqlite.Pool.use] lends one, and
    give it back when [work] returns. [`Pool `Busy] -- no connection within the
    wait -- joins the work's own failures, so that an overloaded server says so
    instead of answering late, and so does [`Pool `Closed], at once, for a pool
    closed or closing under the borrow; {!Spindle_sqlite.refusal} words both. *)

val exec :
  ?wait:Mtime.Span.t ->
  t ->
  ('p, 'r) Rowtype.statement ->
  'p ->
  ('r, [> `Pool of [ `Busy | `Closed ] | Rowtype.error ]) result
(** One statement on a borrowed connection: {!use} around [Rowtype_sqlite.run],
    for the read that is the whole of its work. It is not [run], which is the
    pool's own bracket ({!val-run}).

    {[
    Spindle_sqlite.Pool.exec pool all_users ()
    |> Result.map_error Spindle_sqlite.refusal
    ]} *)

val transaction :
  ?wait:Mtime.Span.t ->
  ?keep:('e -> bool) ->
  ?behaviour:Rowtype_sqlite.Transaction.behaviour ->
  ?retries:int ->
  t ->
  (Rowtype_sqlite.conn ->
  ( 'a,
    ([> Rowtype_sqlite.Transaction.failure | `Pool of [ `Busy | `Closed ] ]
     as
     'e) )
  result) ->
  ('a, 'e) result
(** {!use} and [Rowtype_sqlite.Transaction.within] together: borrow a connection
    and run one transaction on it, begun as [behaviour] says and run again up to
    [retries] times, [Ok] committing and [Error] rolling back unless [keep] says
    otherwise. A transaction that reads and then writes begins [Immediate], or
    its write may find another connection wrote since it read. Every failure of
    its own arrives in the caller's error type:

    {[
    Spindle_sqlite.Pool.transaction ~behaviour:Immediate pool (fun db ->
        let* id = Sq.run db add_user (name, email) in
        let* () = Sq.run db log_event (id, "signed_up") in
        Ok id)
    ]} *)

type stats = Rowtype_sqlite.Pool.stats = {
  size : int;
  idle : int;
  waiting : int;
}

val stats : t -> stats
(** As [Rowtype_sqlite.Pool.stats]. *)

val measure : ?name:string -> t -> Spindle.Metrics.t -> unit
(** The pool's connections as gauges, read from {!val-stats} whenever the
    metrics are, so the pool keeps no count of its own: OpenTelemetry's
    [db.client.connection.count] by [db.client.connection.state], [idle] or
    [used], and [db.client.connection.pending_requests], the borrows waiting --
    each under [db.client.connection.pool.name], [sqlite] unless named, so two
    pools measured on one registry are two series of each. *)

val check : ?name:string -> t Spindle.Dep.t -> Spindle.Health.check
(** The pool [db] reads as a readiness check, [sqlite] unless named: a
    connection borrowed and [select 1] answered, within the pool's wait. A pool
    with no connection idle passes without a borrow, since every one of them is
    lent to a request -- failing it would take a server out of service for being
    busy, which is when it is needed most. A pool {!close}d, or closing, fails
    it. *)

val close : t -> unit
(** As [Rowtype_sqlite.Pool.close]. *)

val run :
  ?size:int ->
  ?wait:Mtime.Span.t ->
  ?timeout:Mtime.Span.t ->
  < mono_clock : _ Eio.Time.Mono.t ; .. > ->
  string ->
  (t -> 'a) ->
  'a
(** [run env file f] is a program's pool: {!create}d on a switch of its own,
    with the monotonic clock taken from [env], handed to [f], and {!close}d when
    [f] returns or raises; cancelled, it passes the cancellation on, its
    connections ending with the switch --

    {[
    Eio_main.run @@ fun env ->
    Spindle_sqlite.Pool.run env "app.db" @@ fun pool ->
    Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
    ]}

    Every option is {!create}'s. A pool that cannot be opened -- a directory
    that is not there, a file that is no database -- is an [error] line on
    [spindle-sqlite] saying why, and the program exits with status 1, because a
    server that cannot reach its database has nothing to serve. A program that
    would rather go on without one calls {!create}. *)
