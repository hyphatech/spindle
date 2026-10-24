(* The same on Postgres: a pool of its connections, and a route that runs a
   statement on it -- / answers the names of the databases on the server.

     docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
     dune exec examples/sql_query.exe *)

let database = "postgres://postgres:postgres@localhost:5432/postgres"

(* The pool makes every connection at once, so a database that refuses is a
   server that does not start. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_postgres.Pool.run env database @@ fun pool ->
  Spindle.serve env
    ~resources:[ Spindle.Dep.resource Databases_routes.db pool ]
    Databases_routes.routes
