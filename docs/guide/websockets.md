# WebSockets

A WebSocket is a **protocol declared once** -- what a client sends and what
a server sends, each JSON of a description, text or bytes, with a
subprotocol name where it has one -- and each end holds a socket typed from
its own side: a route's receives what the client sends, a caller's what the
server does.

```ocaml
module Ws = Spindle.Websocket

type said = { text : string } [@@deriving wiretype]

let chat = Ws.protocol ~client:(Ws.json said_json) ~server:(Ws.json said_json) ()

let echo =
  Spindle.get
    Path.(s "echo")
    (Spindle.Returns.websocket chat)
    (Spindle.Dep.return
       (Ok
          (fun ws ->
            let rec loop () =
              let* said = Ws.receive ws in
              let* () = Ws.send ws said in
              loop ()
            in
            loop ())))

(* The same protocol, from the other end. *)
Spindle_client.websocket client chat "wss://example.com/echo" (fun ws ->
  let* () = Ws.send ws { text = "hi" } in
  Ws.receive ws)
```

**A socket that carries no JSON says what it carries instead**: text as it
is, or bytes as they are, each a `string` at both ends.

```ocaml
let lines = Ws.protocol ~client:Ws.text ~server:Ws.text ()
let frames = Ws.protocol ~client:Ws.binary ~server:Ws.binary ()
```

**A handler returns a result**, so a loop written with `let*` ends at the
first thing that went wrong and says which -- `Closed` with its code and
reason, `Lost`, or `Unreadable` -- and **how it ended is the close**: `Ok`
is 1000, a message its description could not read 1007, a handler that
raised 1011 and is logged; a socket already closed or lost has nothing left
to close, and a handler that wants another code calls `close` and returns.
Nothing raises into the application, and nothing cancels a handler whose
socket has gone: it learns at its next `receive` or `send`. A value its
description cannot encode is our bug, logged, and nothing is sent.

**The framework runs the protocol.** The handshake is checked before the
endpoint runs: a request that opens no socket is `426 upgrade_required`
naming `websocket`, one in another version the same naming 13, a malformed
one `400 invalid` at the header that is wrong -- and **an upgrade from
another site's page is `403 cross_origin`, though it is a `GET`**, because
a browser opens a socket with the page's cookies. The endpoint then answers
`Ok handler`, or a refusal before the upgrade. After it: masks checked both
ways, fragments put together, text checked as UTF-8 (1007), a message of a
kind the socket does not carry refused (1003), one past `~max_message` (1
MiB) refused (1009), a ping answered with its pong, the closing handshake
completed. A message is handed to `receive` as it is taken, so the reader
reads nothing further until then and a socket nobody reads pushes back on
the connection; the peer's close is handed over after every message before
it, so a handler answers those first, and is answered after a second for a
handler that is not listening. Once a close has gone, no message follows it.
A ping goes after `~keep_alive_s` (15) of silence, and a peer silent for
twice that is `Lost`; a write is flushed in sixteen KiB pieces, each bounded
by the server's send limit. A server that is stopping tells every socket
while it can still write, and each closes with 1001 inside the drain, which
counts a socket in flight while it lasts. One log line when a socket ends,
how long it lived and why.

**Broadcast** carries a socket's messages encoded once, as it carries
events: `Websocket.encode` makes one, and `send_encoded` sends it to each
subscriber's socket.

**The client** is a bracket: `Spindle_client.websocket` opens a `ws://` or
`wss://` URL over its own connection code and TLS, on a switch of its own,
runs the function, and closes the connection after it -- a socket is never
kept and never lent. `~timeout_s` bounds the handshake and then each write;
it offers the protocol's name and insists on it, checks the answer proves it
read its key, and masks with the generator TLS is seeded with. It answers
`Failed` -- the handshake could not be made, as a call's error -- `Refused`
-- answered without a `101`, with the answer -- or `Ended` with the
function's own.

**Tested in-process**, as a route is: `Spindle.Test.websocket app protocol
path f` opens a socket as a browser does and runs `f` on the caller's end
over a pair of sockets and no port, answering `Refused` for a route that
refused the upgrade; the clocks never move, so no keep-alive fires in a test
that did not ask. **Described** as far as OpenAPI can: a `101`, its words
naming both sides, and `x-websocket` with each side's schema; the zod module
says `{ websocket: { client, server } }`, so a browser is typed from the
route. `test_websocket_rfc` holds a row for each requirement of RFC 6455
either end meets.

`Response.takeover` is what it is built on: a route taking its connection
over gets a `Response.connection` -- the reader, the writer, the server's
monotonic clock, its send limit, and a promise resolved when the server
begins to stop -- and `Spindle.Websocket.run_server` and `run_client` run
one end over any connection whose handshake is done.

## An echo, and its caller

=== "Server"

    ```ocaml
    --8<-- "websocket_server.ml"
    ```

=== "Client"

    ```ocaml
    --8<-- "websocket_client.ml"
    ```
