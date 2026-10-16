(* An application's command line: its API's document and its client's Zod
   schemas, written from the routes without serving them.

     dune exec examples/api_cli.exe -- api openapi
     dune exec examples/api_cli.exe -- api zod -o wire.gen.ts
     dune exec examples/api_cli.exe -- api check \
       --openapi openapi.json --zod wire.gen.ts *)

open Spindle.Syntax

type note = { id : int; text : string } [@@deriving wiretype]

let note_id = Spindle.Path.int "note_id"

let routes =
  [
    Spindle.get ~summary:"One note"
      Spindle.Path.(s "notes" / note_id)
      (Spindle.Returns.json note_json)
      (let+ id = Spindle.param note_id in
       Ok { id; text = "Buy milk" });
  ]

(* --8<-- [start:app] *)
(* The app is only described, never started, so a resource its routes read
   -- a pool, a client -- need not exist. *)
let () =
  Spindle_cli.run ~name:"notes" ~title:"Notes" ~app:(Spindle.App.make routes) ()
(* --8<-- [end:app] *)
