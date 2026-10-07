(* An application's command line: its API's document and its client's zod
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
(* The app is only described, so it is made from nothing a request would
   need: no database, no service it calls. *)
let app _env ~sw:_ = Spindle.App.make routes
let () = Spindle_cli.run ~name:"notes" ~title:"Notes" ~app ()
(* --8<-- [end:app] *)
