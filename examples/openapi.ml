(* JSON in and out, and the API's document made from the routes:
   /openapi.json is OpenAPI 3.2, and /docs is a reference to read it by.

   Nothing is described twice. What a route reads, what it answers and every
   code it may refuse with are values on the route, so the document is read
   from them. *)

(* [docs] is the document of the routes it is given, at /openapi.json, and
   the reference over it at /docs: routes like any others, served beside
   the ones they describe. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env
    (Greetings.routes
    @ Spindle.Openapi.routes ~title:"Greetings" Greetings.routes)
