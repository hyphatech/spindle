(* A JSON body in, a JSON answer out, and a refusal of the application's
   own: POST /orders places an order, 201 with what was placed.

     curl -i localhost:8080/orders -H 'content-type: application/json' \
       -d '{"item": "tea", "quantity": 2}'
     curl -i localhost:8080/orders -H 'content-type: application/json' \
       -d '{"item": "tea", "quantity": 0}'
     curl -i localhost:8080/orders -H 'content-type: application/json' \
       -d '{"item": "cake", "quantity": 1}' *)

open Spindle.Syntax

(* --8<-- [start:app] *)
(* The shape and its bounds are the description's: a quantity of 0 is a 400
   at body.quantity before the endpoint runs. *)
type order = { item : string; quantity : int [@min 1] [@max 20] }
[@@deriving wiretype]

type placed = { number : int; item : string; quantity : int }
[@@deriving wiretype]

(* A rule the description cannot know is the endpoint's, refused with a code
   declared once, with its status and what it means. *)
let sold_out =
  Spindle.Refusal.Code.make "sold_out" ~status:`Conflict
    ~doc:"The item is sold out."

let menu = [ ("tea", true); ("coffee", true); ("cake", false) ]

let place ({ item; quantity } : order) =
  match List.assoc_opt item menu with
  | Some true -> Ok { number = 1; item; quantity }
  | Some false | None ->
      Error
        (Spindle.Refusal.make sold_out
           (Printf.sprintf "There is no %s left today." item))

let routes =
  [
    Spindle.post ~refuses:[ sold_out ]
      Spindle.Path.(s "orders")
      (Spindle.Returns.json ~status:`Created placed_json)
      (let+ order = Spindle.json order_json in
       place order);
  ]
(* --8<-- [end:app] *)

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
