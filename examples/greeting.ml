(* The landing page's program: a type, a handler, a route and a server, each
   on its own so a reader new to OCaml can see how they fit together.
   /hello/Hypha answers {"text":"Hello, Hypha!"}, and /docs describes it. *)

(* --8<-- [start:app] *)
open Spindle.Syntax

type greeting = { text : string } [@@deriving wiretype]

let hello name = Ok { text = "Hello, " ^ name ^ "!" }
let name = Spindle.Path.str "name"

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
  Spindle.serve env (routes @ Spindle.Openapi.docs routes)
(* --8<-- [end:app] *)
