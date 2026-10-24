open Spindle.Syntax

type greeting = { text : string } [@@deriving wiretype]

let hello name = Ok { text = "Hello, " ^ name ^ "!" }
let name = Spindle.Path.string "name"

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello" / name)
      (Spindle.Returns.json greeting_json)
      (let+ name = Spindle.param name in
       hello name);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Openapi.routes routes)
