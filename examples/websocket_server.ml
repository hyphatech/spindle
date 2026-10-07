(* A WebSocket: GET /echo opens one, and whatever the client says comes
   back to it.

   What each side sends is declared once, as a protocol, and the route
   serves it: the framework runs the protocol itself -- the handshake, the
   frames, ping and pong, the close -- and the handler only receives and
   sends. A loop written with [let*] ends at the first thing that went
   wrong, and how it ended decides how the socket is closed: a message the
   description cannot read closes it with 1007. *)

module Ws = Spindle.Websocket

let ( let* ) = Result.bind

type said = { text : string } [@@deriving wiretype]

let protocol =
  Ws.protocol ~client:(Ws.json said_json) ~server:(Ws.json said_json) ()

let echo ws =
  let rec loop () =
    let* said = Ws.receive ws in
    let* () = Ws.send ws said in
    loop ()
  in
  loop ()

let routes =
  [
    Spindle.get
      Spindle.Path.(s "echo")
      (Spindle.Returns.websocket protocol)
      (Spindle.Dep.return (Ok echo));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
