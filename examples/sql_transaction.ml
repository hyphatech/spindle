(* A write in one transaction, and an answer that says what became of it:
   PUT /names/{name} claims a name, 201 the first time and 200 every time
   after, with when it was first claimed.

     rowtype-migrate create --url sqlite:names.db
     rowtype-migrate up --dir examples/migrations --url sqlite:names.db
     dune exec examples/sql_transaction.exe
     curl -i -X PUT localhost:8080/names/ada     201
     curl -i -X PUT localhost:8080/names/ada     200 *)

open Spindle.Syntax
module S = Rowtype
module Sq = Rowtype_sqlite

type claim = { name : string; claimed_at : Ptime.t } [@@deriving wiretype]

(* The database says whether this request made the row: an insert that meets
   one already there changes nothing, and counts none. *)
let insert_name =
  S.exec_count ~params:(S.t2 S.text S.instant)
    "insert into names (name, claimed_at) values ($1, $2) on conflict (name) \
     do nothing"

let when_claimed =
  S.find ~params:S.text ~row:S.instant
    "select claimed_at from names where name = $1"

(* --8<-- [start:claim] *)
(* One transaction, so the name is claimed and read in one go: [Ok] commits
   both statements and a failure rolls both back. *)
let claim pool name ~now =
  Spindle_sqlite.Pool.transaction ~behaviour:Immediate pool (fun db ->
      let* made = Sq.run db insert_name (name, now) in
      let* claimed_at = Sq.run db when_claimed name in
      Ok ((if made = 1 then `Created else `OK), { name; claimed_at }))
  |> Result.map_error Spindle_sqlite.refusal
(* --8<-- [end:claim] *)

let name = Spindle.Path.string "name"

let db : Spindle_sqlite.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

(* Every branch returns the status it reached, and the route lists each with
   when it happens, which is what the API's document says of it. *)
let routes =
  [
    Spindle.put ~summary:"Claim a name"
      Spindle.Path.(s "names" / name)
      (Spindle.Returns.json_response claim_json
         ~statuses:
           [
             (`Created, "The name was free, and is now claimed.");
             (`OK, "The name was claimed already.");
           ])
      (let+ pool = db and+ name = Spindle.param name and+ now = Spindle.now in
       claim pool name ~now);
  ]

(* The table is the migration's, made before the server starts: a server
   that made it would race every other instance of itself to. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_sqlite.Pool.run env "names.db" @@ fun pool ->
  Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
