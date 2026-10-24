(* Claiming a name, in one transaction: the write sql_transaction's route
   makes. *)

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

(* One transaction, so the name is claimed and read in one go: [Ok] commits
   both statements and a failure rolls both back. *)
let claim pool name ~now =
  Spindle_sqlite.Pool.transaction ~behaviour:Immediate pool (fun db ->
      let* made = Sq.run db insert_name (name, now) in
      let* claimed_at = Sq.run db when_claimed name in
      Ok ((if made = 1 then `Created else `OK), { name; claimed_at }))
  |> Result.map_error Spindle_sqlite.refusal
