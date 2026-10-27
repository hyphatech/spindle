(* The route sql_postgres serves: the names of the databases on the server,
   read through the pool. *)

open Spindle.Syntax
module S = Rowtype

let databases =
  S.list ~params:S.unit ~row:S.text
    "select datname from pg_database order by datname"

(* A borrow that waits past the pool's limit is [`Pool `Busy], which [refusal]
   answers 503: an overloaded server says so rather than answering late. *)
let list_databases pool =
  Spindle_postgres.Pool.exec pool databases ()
  |> Result.map_error Spindle_postgres.refusal

(* The pool, as the routes read it: supplied where the server starts. *)
let db : Spindle_postgres.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

let routes =
  List.map Spindle.Access.public
    [
      Spindle.get Spindle.Path.root
        (Spindle.Returns.json (Wiretype.list Wiretype.string))
        (let+ pool = db in
         list_databases pool);
    ]
