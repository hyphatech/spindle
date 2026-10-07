(* Server-Sent Events: GET /count sends a number a second, each with its id,
   and a client that reconnects carries on after the last number it was sent
   instead of starting again. A browser's EventSource reconnects by itself
   and says where it was in the Last-Event-ID header, so resuming is the one
   thing the route has to do.

   What the stream sends is declared on the route, as an answer is, so the
   API's document describes each event and the compiler refuses one the
   route did not declare. *)

open Spindle.Syntax

let ( let* ) = Result.bind

(* The events one stream may send are a type of their own, and each kind is
   declared as one of them. *)
type counting

let count : (int, counting) Spindle.Event.kind =
  Spindle.Event.json "count" Wiretype.int

let count_from ~clock n send =
  let rec go n =
    let* () = send (Spindle.Event.make ~id:(string_of_int n) count n) in
    Eio.Time.sleep clock 1.0;
    go (n + 1)
  in
  go n

let routes ~clock =
  [
    Spindle.get
      Spindle.Path.(s "count")
      (Spindle.Returns.events Spindle.Event.[ declare count ])
      (let+ last = Spindle.Header.optional "last-event-id" Spindle.Codec.int in
       Ok (count_from ~clock (Option.fold ~none:1 ~some:succ last)));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes ~clock:(Eio.Stdenv.clock env))
