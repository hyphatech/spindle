(** Sessions in a table of the application's database, for a server of more than
    one process ({!Spindle.Session}).

    {[
    (* the table, made by a migration of the application's own, is
       Spindle_postgres.Session.schema ~table:"sessions" *)
    let sessions =
      Spindle.Session.create
        ~store:(Spindle_postgres.Session.store pool ~table:"sessions")
        ~idle_s:(14 * 86400) ~absolute_s:(90 * 86400) visit_json
    ]}

    The table is the application's, made by a migration of its own, since
    migrating is a step before the server starts and never the server's; its
    statements are {!statements}, for [Rowtype_postgres.verify] beside the
    application's others. {b Each call borrows a connection of its own} and
    gives it back: a session is data about a visit, not a row a handler's
    transaction must agree with, and a store is a record of functions over a
    digest, which has no connection to be handed. [table] is a constant written
    in source, and one that is no lowercase identifier raises
    [Invalid_argument], since it is written into each statement. *)

val schema : table:string -> string
(** The SQL that makes the table and its index, each commented. *)

val statements : table:string -> Rowtype.any list
(** Every statement the store runs. *)

val store : Pool.t -> table:string -> Spindle.Session.store
(** The store over [table], each call on a connection borrowed from [pool]; an
    [Error] is the database's failure in words, the statement's values left out.
*)
