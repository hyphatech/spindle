(* A pool of connections to a SQLite file, and a route that runs a statement
   on it: /names answers the names claimed, which sql_transaction claims.

     rowtype-migrate create --url sqlite:names.db
     rowtype-migrate up --dir examples/migrations --url sqlite:names.db
     dune exec examples/sql_query.exe *)

open Spindle.Syntax
module S = Rowtype

(* --8<-- [start:query] *)
let claimed =
  S.list ~params:S.unit ~row:S.text "select name from names order by name"

(* A borrow that waits past the pool's limit is [`Pool `Busy], which [refusal]
   answers 503: an overloaded server says so rather than answering late. *)
let list_names pool =
  Spindle_sqlite.Pool.exec pool claimed ()
  |> Result.map_error Spindle_sqlite.refusal
(* --8<-- [end:query] *)

(* --8<-- [start:routes] *)
(* The pool, as the routes read it: supplied where the server starts. *)
let db : Spindle_sqlite.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

let routes =
  [
    Spindle.get
      Spindle.Path.(s "names")
      (Spindle.Returns.json (Wiretype.list Wiretype.string))
      (let+ pool = db in
       list_names pool);
  ]
(* --8<-- [end:routes] *)

(* --8<-- [start:pool] *)
(* The pool opens every connection at once, so a file that cannot be opened
   is a server that does not start. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_sqlite.Pool.run env "names.db" @@ fun pool ->
  Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
(* --8<-- [end:pool] *)
