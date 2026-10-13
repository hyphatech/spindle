(** Postgres for a Spindle server, over rowtype's Postgres backend: connections
    bounded as a server bounds them, a pool and the probe that asks it, and the
    refusal a database failure answers.

    A transaction is the backend's ([Rowtype_postgres.Transaction]), and
    migrating is [rowtype-migrate]'s, a step of its own before the server
    starts. *)

module Pool = Pool
module Session = Session

type error =
  [ Rowtype.error
  | Rowtype_postgres.Transaction.failure
  | `Pool of
    [ `Busy  (** no connection within the wait *)
    | `Closed  (** the pool is closed, answered at once *) ]
    (** what a borrow met in the pool, a state of the pool's own *) ]
(** Every failure this library answers: a statement's, and a pool's or a
    transaction's own. *)

val error_to_string : [< error ] -> string
(** A failure in words for a log, as rowtype tells it: a statement's as
    [Rowtype.error_to_string] does, a transaction's and a pool's own as
    [Rowtype_postgres]'s printers do. No value is in the words. *)

val refusal : [< error ] -> Spindle.Refusal.t
(** The default wording, for whatever a route does not answer itself:
    [`Pool `Busy], and a [`Not_serializable] its retries did not get past, are
    [503 busy] with [Retry-After: 1], "The server is busy. Please try again in a
    moment.", since asking again is what may succeed -- [`Pool `Busy] logged as
    a warning, since a pool with nothing free is a server under load, not a bug.
    [`Pool `Closed] is the same [503 busy], logged as a warning with no detail,
    since a pool closed under a request is a server shutting down; the rest is
    {!Spindle.Refusal.internal}, the detail in the log. A [`Conflict] included,
    whether a statement found it or a [DEFERRABLE] constraint refused a
    transaction's [COMMIT] -- a route that expects one matches it first, by its
    constraint, and answers a code it declares:

    {[
    match Spindle_postgres.Pool.query pool add_user (name, email) with
    | Ok id -> Ok id
    | Error (`Conflict (Some "users_email_key")) ->
        Error (Spindle.Refusal.make email_taken "That address is taken.")
    | Error e -> Error (Spindle_postgres.refusal e)
    ]} *)

val connect :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  ?statement_timeout:Mtime.Span.t ->
  ?idle_in_transaction_timeout:Mtime.Span.t ->
  ?connect_timeout:Mtime.Span.t ->
  ?parameters:(string * string) list ->
  ?timeout:Mtime.Span.t ->
  ?statement_cache:int ->
  string ->
  (Rowtype_postgres.conn, [> Rowtype.error ]) result
(** [connect ~sw ~net ~mono_clock target] -- a [postgres://] URL or a keyword
    list -- with every statement bounded by [statement_timeout] (10 s) and every
    transaction left idle by [idle_in_transaction_timeout] (30 s), so a query
    that hangs or a transaction somebody forgot is ended by the server rather
    than holding a pooled connection and its locks. The bounds are start-up
    parameters, written in whole milliseconds rounded up, so a span under a
    millisecond is still a bound and only a span of zero lifts one, as Postgres
    reads [0]; with [DateStyle=ISO], which is how [Rowtype.instant] reads one,
    and [parameters] after them -- an application's own, [client_min_messages]
    say, winning over the framework's where they name one -- so a connection
    made again keeps every one.

    Connecting waits at most [connect_timeout] (10 s) unless the connection
    string says [connect_timeout] itself. [timeout] and [statement_cache] are
    [Rowtype_postgres.connect]'s, passed through.

    Each statement it runs in a kept trace is a span ({!Spindle.Trace}), a
    [Client] one named [postgresql] with its text as [db.query.text] and never
    its parameters -- and so is each a {!Pool}'s connections run. *)
