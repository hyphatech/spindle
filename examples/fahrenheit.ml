(* A typed query parameter: /fahrenheit?celsius=21 answers
   {"fahrenheit":69.8}. The parameter arrives as a float, so the handler is
   arithmetic and nothing else; /fahrenheit?celsius=warm and a missing one
   are refused at [query.celsius] before it runs. *)

open Spindle.Syntax

type reading = { fahrenheit : float } [@@deriving wiretype]

let to_fahrenheit celsius = Ok { fahrenheit = (celsius *. 9. /. 5.) +. 32. }
let celsius = Spindle.Query.required "celsius" Wiretype.number

let routes =
  [
    Spindle.get
      Spindle.Path.(s "fahrenheit")
      (Spindle.Returns.json reading_json)
      (let+ celsius = celsius in
       to_fahrenheit celsius);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Openapi.routes routes)
