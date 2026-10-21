(** Sessions in a table of the application's database ({!Spindle.Session}).

    {[
    let session =
      Spindle.Session.create
        ~store:(Spindle_sqlite.Session.store db)
        ~idle:Mtime.Span.(14 * day)
        ~absolute:Mtime.Span.(90 * day)
        visit_json
    ]}

    The table is {!default_table} unless given another, made by the migration
    this package installs: [rowtype-migrate up --source spindle-sqlite] applies
    it, before the application's own, since migrating is a step before the
    server starts and never the server's. A table of another name is the
    application's to make, in a migration of its own, from {!schema}. Its
    statements are {!statements}, for [Rowtype_sqlite.verify] beside the
    application's others. {b Each call borrows a connection of its own} and
    gives it back: a session is data about a visit, not a row a handler's
    transaction must agree with. [table] is a constant written in source, and
    one that is no lowercase identifier raises [Invalid_argument] where the
    store is made, since it is written into each statement, quoted, so a word
    SQL reserves -- [user], [order] -- is a table's name like any other. *)

val default_table : string
(** [spindle_sessions], the table the installed migration makes. *)

val schema : table:string -> string
(** The SQL that makes the table and its index, each commented. *)

val statements : ?table:string -> unit -> Rowtype.any list
(** Every statement the store runs. *)

val store :
  ?table:string -> Pool.t Spindle.Dep.t -> Spindle.Session.store Spindle.Dep.t
(** The store over [table], each call on a connection borrowed from the pool
    [db] reads -- the resource every route reads it through -- for a session's
    [~store]. Its statements are written once, here. An [Error] is the
    database's failure in words, the statement's values left out. *)
