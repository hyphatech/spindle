(* The routes sql_query serves, reading the pool as a dependency. *)

open Spindle.Syntax

(* The pool, as the routes read it: supplied where the server starts. *)
let db : Spindle_sqlite.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

let routes =
  List.map Spindle.Access.public
    [
      Spindle.get
        Spindle.Path.(s "names")
        (Spindle.Returns.json (Wiretype.list Wiretype.string))
        (let+ pool = db in
         Names_query.list_names pool);
    ]
