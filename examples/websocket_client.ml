(* The other end of websocket_server.ml: a client that opens its /echo, says three
   things and hears each come back. Run the server first, then this:

     dune exec examples/websocket_server.exe
     dune exec examples/websocket_client.exe

   The protocol is the server's, from the client's side: this socket sends
   what the client sends and receives what the server does. Two programs
   declare it twice here; an application whose two ends are separate
   programs puts it in a library both link, so they cannot drift apart.

   The call is a bracket: the connection lives while the function runs and
   is closed after it, and the answer is what the function returned -- here,
   what it heard -- or why the socket, or the handshake, ended first, which
   the log has already said. *)

module Ws = Spindle.Websocket

let ( let* ) = Result.bind

type said = { text : string } [@@deriving wiretype]

let protocol =
  Ws.protocol ~client:(Ws.json said_json) ~server:(Ws.json said_json) ()

let converse ws =
  let rec say heard = function
    | [] -> Ok (List.rev heard)
    | text :: rest ->
        let* () = Ws.send ws { text } in
        let* back = Ws.receive ws in
        say (back.text :: heard) rest
  in
  say [] [ "hello"; "is anybody there"; "goodbye" ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_client.run env @@ fun client ->
  match
    Spindle_client.websocket client protocol "ws://localhost:8080/echo" converse
  with
  | Ok heard -> List.iter (fun text -> print_endline ("heard: " ^ text)) heard
  | Error _ -> () (* the socket's log line has said why *)
