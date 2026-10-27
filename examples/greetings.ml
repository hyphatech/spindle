(* The routes openapi describes: JSON in and out, and a refusal of the
   application's own. *)

open Spindle.Syntax

(* A body and an answer are records; their descriptions are derived. *)
type greeting_request = { name : string; language : string }
[@@deriving wiretype]

type greeting = { text : string } [@@deriving wiretype]

(* A code is declared once, with its status and what it means, and the
   document lists it under every route that may answer it. *)
let unknown_language =
  Spindle.Refusal.Code.make "unknown_language" ~status:`Unprocessable_content
    ~doc:"The language is not one of /languages."

let hellos = [ ("en", "Hello"); ("fr", "Bonjour"); ("uk", "Привіт") ]
let languages = Ok (List.map fst hellos)

let greet { name; language } =
  match List.assoc_opt language hellos with
  | Some hello -> Ok { text = Printf.sprintf "%s, %s!" hello name }
  | None ->
      Error
        (Spindle.Refusal.make unknown_language
           (Printf.sprintf "There is no greeting in %s." language))

let routes =
  List.map Spindle.Access.public
    [
      Spindle.get ~summary:"The languages a greeting can be in"
        Spindle.Path.(s "languages")
        (Spindle.Returns.json (Wiretype.list Wiretype.string))
        (Spindle.Dep.return languages);
      Spindle.post ~summary:"A greeting, by name" ~refuses:[ unknown_language ]
        Spindle.Path.(s "greetings")
        (Spindle.Returns.json greeting_json)
        (let+ request = Spindle.json greeting_request_json in
         greet request);
    ]
