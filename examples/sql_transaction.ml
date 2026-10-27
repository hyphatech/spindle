(* A write in one transaction, and an answer that says what became of it:
   PUT /names/{name} claims a name, 201 the first time and 200 every time
   after, with when it was first claimed.

     rowtype-migrate create --url sqlite:names.db
     rowtype-migrate up --dir examples/migrations --url sqlite:names.db
     dune exec examples/sql_transaction.exe
     curl -i -X PUT localhost:8080/names/ada     201
     curl -i -X PUT localhost:8080/names/ada     200 *)

open Spindle.Syntax

let name = Spindle.Path.string "name"

let db : Spindle_sqlite.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

(* Every branch returns the status it reached, and the route lists each with
   when it happens, which is what the API's document says of it. *)
let routes =
  [
    Spindle.put ~summary:"Claim a name"
      Spindle.Path.(s "names" / name)
      (Spindle.Returns.json_response Name_claim.claim_json
         ~statuses:
           [
             (`Created, "The name was free, and is now claimed.");
             (`OK, "The name was claimed already.");
           ])
      (let+ pool = db and+ name = Spindle.param name and+ now = Spindle.now in
       Name_claim.claim pool name ~now);
  ]

(* The table is the migration's, made before the server starts: a server
   that made it would race every other instance of itself to. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_sqlite.Pool.run env "names.db" @@ fun pool ->
  Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
