(* A pool of connections to a SQLite file, and a route that runs a statement
   on it: /names answers the names claimed, which sql_transaction claims.

     rowtype-migrate create --url sqlite:names.db
     rowtype-migrate up --dir examples/migrations --url sqlite:names.db
     dune exec examples/sql_query.exe *)

(* The pool opens every connection at once, so a file that cannot be opened
   is a server that does not start. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_sqlite.Pool.run env "names.db" @@ fun pool ->
  Spindle.serve env
    ~resources:[ Spindle.Dep.resource Names_routes.db pool ]
    Names_routes.routes
