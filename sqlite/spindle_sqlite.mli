(** SQLite for a Spindle server, over rowtype's SQLite backend: a pool of
    connections to one file, in WAL mode so a read never waits on a write, the
    probe that asks it, and the refusal a database failure answers.

    A transaction is the backend's ([Rowtype_sqlite.Transaction]), and migrating
    is [rowtype-migrate]'s, a step of its own before the server starts:
    [rowtype-migrate up --url sqlite:app.db]. *)

module Pool = Pool
module Session = Session

type error =
  [ Rowtype.error
  | Rowtype_sqlite.Transaction.failure
  | Rowtype_sqlite.Pool.error ]
(** Every failure this library answers: a statement's, and a pool's or a
    transaction's own -- [`Pool `Busy], no connection within the wait, and
    [`Pool `Closed], a pool closed, answered at once. *)

val error_to_string : [< error ] -> string
(** A failure in words for a log, as [Rowtype_sqlite.error_to_string] tells it.
    No value is in the words. *)

val refusal : [< error ] -> Spindle.Refusal.t
(** The default wording, for whatever a route does not answer itself:

    {table
      {tr {th Failure } {th Answer } {th Logged } }
      {tr {td [`Pool `Busy] } {td [503 busy] } {td a warning } }
      {tr {td [`Not_serializable] } {td [503 busy] } {td the detail } }
      {tr {td [`Pool `Closed] } {td [503 busy] } {td a warning } }
      {tr {td [`Unsent] } {td [503 busy] } {td a warning, with why } }
      {tr {td anything else } {td [500 internal] } {td the detail } }
    }

    [503 busy] carries [Retry-After: 1], since asking again is what may succeed:
    no connection free within the wait is a server under load; a
    [`Not_serializable] is another connection's lock held past the wait, which
    SQLite's single writer meets under writes, and its retries did not get past;
    and a pool closed under a request is a server shutting down. The rest is
    {!Spindle.Refusal.internal}, the detail in the log -- a [`Conflict]
    included, which a route that expects one matches first, by the columns
    SQLite names, and answers a code it declares:

    {[
    match Spindle_sqlite.Pool.exec pool add_user (name, email) with
    | Ok id -> Ok id
    | Error (`Conflict (Some "users.email")) ->
        Error (Spindle.Refusal.make email_taken "That address is taken.")
    | Error e -> Error (Spindle_sqlite.refusal e)
    ]} *)
