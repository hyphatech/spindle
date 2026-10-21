(* The same on Postgres: a pool of its connections, and a route that runs a
   statement on it -- / answers the names of the databases on the server.

     docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
     dune exec examples/sql_query.exe *)

open Spindle.Syntax
module S = Rowtype

let database = "postgres://postgres:postgres@localhost:5432/postgres"

(* --8<-- [start:query] *)
let databases =
  S.list ~params:S.unit ~row:S.text
    "select datname from pg_database order by datname"

(* A borrow that waits past the pool's limit is [`Pool `Busy], which [refusal]
   answers 503: an overloaded server says so rather than answering late. *)
let list_databases pool =
  Spindle_postgres.Pool.exec pool databases ()
  |> Result.map_error Spindle_postgres.refusal
(* --8<-- [end:query] *)

(* --8<-- [start:routes] *)
(* The pool, as the routes read it: supplied where the server starts. *)
let db : Spindle_postgres.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

let routes =
  [
    Spindle.get Spindle.Path.root
      (Spindle.Returns.json (Wiretype.list Wiretype.string))
      (let+ pool = db in
       list_databases pool);
  ]
(* --8<-- [end:routes] *)

(* --8<-- [start:pool] *)
(* The pool makes every connection at once, so a database that refuses is a
   server that does not start. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_postgres.Pool.run env database @@ fun pool ->
  Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
(* --8<-- [end:pool] *)
