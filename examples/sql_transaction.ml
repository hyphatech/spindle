(* A write in one transaction, and an answer that says what became of it:
   PUT /names/{name} claims a name, 201 the first time and 200 every time
   after, with when it was first claimed.

     docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
     dune exec examples/sql_transaction.exe
     curl -i -X PUT localhost:8080/names/ada     201
     curl -i -X PUT localhost:8080/names/ada     200 *)

open Spindle.Syntax
module S = Rowtype
module Pg = Rowtype_postgres

let ( let* ) = Result.bind
let database = "postgres://postgres:postgres@localhost:5432/postgres"

type claim = { name : string; claimed_at : int } [@@deriving wiretype]

let create_names =
  S.exec ~params:S.unit
    "create table if not exists names (name text primary key, claimed_at \
     timestamptz not null)"

(* The database says whether this request made the row: an insert that meets
   one already there changes nothing, and counts none. *)
let insert_name =
  S.exec_count
    ~params:(S.t2 S.text Spindle_postgres.instant)
    "insert into names (name, claimed_at) values ($1, $2) on conflict (name) \
     do nothing"

let when_claimed =
  S.find ~params:S.text ~row:Spindle_postgres.instant
    "select claimed_at from names where name = $1"

(* --8<-- [start:claim] *)
(* One transaction, so the name is claimed and read in one go: [Ok] commits
   both statements and a failure rolls both back. *)
let claim pool name ~now =
  Spindle_postgres.Pool.transaction pool (fun db ->
      let* made = Pg.run db insert_name (name, now) in
      let* claimed_at = Pg.run db when_claimed name in
      Ok ((if made = 1 then `Created else `OK), { name; claimed_at }))
  |> Result.map_error Spindle_postgres.refusal
(* --8<-- [end:claim] *)

let name = Spindle.Path.str "name"

(* Every branch returns the status it reached, and the route lists each with
   when it happens, which is what the API's document says of it. *)
let routes pool =
  [
    Spindle.put ~summary:"Claim a name"
      Spindle.Path.(s "names" / name)
      (Spindle.Returns.json_response claim_json
         ~statuses:
           [
             (`Created, "The name was free, and is now claimed.");
             (`OK, "The name was claimed already.");
           ])
      (let+ name = Spindle.param name and+ now = Spindle.now in
       claim pool name ~now);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_postgres.Pool.run env database @@ fun pool ->
  match Spindle_postgres.Pool.query pool create_names () with
  | Ok () -> Spindle.serve env (routes pool)
  | Error `Busy -> prerr_endline "No connection came free."
  | Error (#S.error as e) -> prerr_endline (S.error_to_string e)
