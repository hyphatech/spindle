(* JSON in and out, and the API's document made from the routes:
   /openapi.json is OpenAPI 3.2, and /docs is a reference to read it by.

   Nothing is described twice. What a route reads, what it answers and every
   code it may refuse with are values on the route, so the document is read
   from them. *)

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

(* --8<-- [start:docs] *)
(* [docs] is the document of the routes it is given, at /openapi.json, and
   the reference over it at /docs: routes like any others, served beside
   the ones they describe. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Openapi.docs ~title:"Greetings" routes)
(* --8<-- [end:docs] *)
