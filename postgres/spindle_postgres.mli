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
  | `Busy  (** no connection within the wait *) ]
(** Every failure this library answers: a statement's, and a pool's or a
    transaction's own. *)

val instant : int Rowtype.ty
(** An instant as {!Spindle.now} gives it, epoch milliseconds, in a
    [timestamptz] column: converted exactly to and from [Rowtype.instant]'s
    [Ptime.t], for years 1 to 9999. One later is written as the latest instant
    of 9999; one earlier is refused by the column. *)

val refusal : [< error ] -> Spindle.Refusal.t
(** The default wording, for whatever a route does not answer itself: [`Busy],
    and a [`Not_serializable] its retries did not get past, are [503 busy] with
    [Retry-After: 1], "The server is busy. Please try again in a moment.", since
    asking again is what may succeed; the rest is {!Spindle.Refusal.internal},
    the detail in the log. A [`Conflict] included -- a route that expects one
    matches it first, by its constraint, and answers a code it declares:

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
  ?statement_timeout_ms:int ->
  ?idle_in_transaction_timeout_ms:int ->
  ?connect_timeout_s:int ->
  ?parameters:(string * string) list ->
  ?timeout_s:float ->
  ?statement_cache:int ->
  string ->
  (Rowtype_postgres.conn, [> Rowtype.error ]) result
(** [connect ~sw ~net ~mono_clock target] -- a [postgres://] URL or a keyword
    list -- with every statement bounded by [statement_timeout_ms] (10 000) and
    every transaction left idle by [idle_in_transaction_timeout_ms] (30 000), so
    a query that hangs or a transaction somebody forgot is ended by the server
    rather than holding a pooled connection and its locks. The bounds are
    start-up parameters, with [DateStyle=ISO], which is how [Rowtype.instant]
    reads one, and [parameters] after them -- an application's own,
    [client_min_messages] say, winning over the framework's where they name one
    -- so a connection made again keeps every one.

    Connecting waits at most [connect_timeout_s] (10) unless the connection
    string says [connect_timeout] itself. [timeout_s] and [statement_cache] are
    [Rowtype_postgres.connect]'s, passed through.

    Each statement it runs in a kept trace is a span ({!Spindle.Trace}), a
    [Client] one named [postgresql] with its text as [db.query.text] and never
    its parameters -- and so is each a {!Pool}'s connections run. *)
