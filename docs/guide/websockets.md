# WebSockets

You declare a WebSocket **protocol** once -- what the client sends and what
the server sends -- and serve it from a route or open it from a client. Each
end gets a socket typed from its own side.

## An echo server

```ocaml
--8<-- "websocket_server.ml"
```

- `Ws.protocol ~client ~server ()` says what each side sends: `Ws.json` of a
  wiretype description, `Ws.text` or `Ws.binary` (each a `string`). Add
  `~subprotocol:"name"` to require a `Sec-WebSocket-Protocol`.
- `Spindle.Returns.websocket protocol` makes the route a socket. Its
  dependency answers `Ok handler`, or a refusal before the upgrade.
- The handler calls `Ws.receive` and `Ws.send` and returns a `result`. A
  `let*` loop stops at the first error: `Closed` (with its code and reason),
  `Lost`, `Unreadable`, or `Unwritable` for a message that cannot be sent --
  JSON its description cannot encode, or text that is not UTF-8.

A plain request to the route is refused with `426`, as below. So is an
upgrade from another site's page (`403 cross_origin`; see
[`~trusted_origins`](cookies.md#csrf-and-cors)), since the browser would
attach your site's cookies to it:

```console
$ curl -i localhost:8080/echo
HTTP/1.1 426 Upgrade Required
upgrade: websocket
...

{"error":"upgrade_required","message":"This address opens a WebSocket, and nothing else."}
```

## Connecting as a client

```ocaml
--8<-- "websocket_client.ml"
```

```console
$ dune exec examples/websocket_client.exe
heard: hello
heard: is anybody there
heard: goodbye
```

`Spindle_client.websocket client protocol url f` opens a `ws://` or `wss://`
URL, runs `f` on the socket and closes it when `f` returns. It answers `f`'s
result, or a call's `` `Unsent `` or `` `Lost `` (the handshake could not be
made), `` `Not_upgraded `` (the server answered without a `101`, with that
answer) or `` `Websocket `` (how the socket ended). `~timeout` bounds the
handshake and each write.

Both programs declare the same protocol. When the two ends are separate
programs, put it in a library both link so they cannot drift apart.

## Closing a socket

How the handler's loop ended is the close code:

| The handler | Close code |
|---|---|
| returns `Ok` | 1000 |
| got a message its description could not read | 1007 |
| had a message its description could not write | 1011 |
| raised (logged as a bug) | 1011 |
| returns `Error (Closed _)` or `Error (Lost _)` | none: the socket has already ended |

To close with another code, call `Ws.close ~code ~reason ws` and return.
Nothing raises into your handler: a socket whose peer has gone answers its
next `receive` or `send` with an error. A `send` you cut off -- under
`Eio.Time.Timeout.run`, or in an `Eio.Fiber.first` it lost -- may have
written part of its frame, so it ends the socket: the cancellation goes on,
and every later `send` answers `Lost`.

The framework handles the rest of the protocol for you:

- ping and pong: a ping after `~keep_alive` (15 s) of silence, and a
  peer silent for twice that is `Lost`;
- a peer that takes nothing written for the server's `send_timeout`
  (30 s) is `Lost`, and one still reading, however slowly, is sent the
  whole message;
- a message over `~max_message` (1 MiB) closes the socket with 1009, and one
  of a kind the socket does not carry with 1003;
- a stopping server closes every socket with 1001;
- one log line when a socket ends: how long it lived and why.

`~keep_alive` and `~max_message` are arguments of
`Spindle.Returns.websocket` and `Spindle_client.websocket`.

## Broadcasting to many sockets

To send one message to many sockets, encode it once with
`Ws.encode (Ws.server protocol) value` and send that to each with
`Ws.send_encoded`. Make the hub a
[`Spindle.Broadcast`](sse.md#broadcasting-to-many-clients) of encoded
messages. A handler that both receives and forwards runs two loops, here
under `Eio.Fiber.first`, which ends both when either does:

```ocaml
let hub : (unit, said Ws.encoded) Spindle.Broadcast.t =
  Spindle.Broadcast.create ()

let chat ws =
  let sub = Spindle.Broadcast.subscribe hub ~topic:"lobby" () in
  Fun.protect ~finally:(fun () -> Spindle.Broadcast.unsubscribe hub sub)
  @@ fun () ->
  let rec listen () =
    let* said = Ws.receive ws in
    Spindle.Broadcast.publish hub ~topic:"lobby"
      (Ws.encode (Ws.server protocol) said);
    listen ()
  in
  let rec forward () =
    match Spindle.Broadcast.next sub with
    | Some message ->
        let* () = Ws.send_encoded ws message in
        forward ()
    | None -> Ok ()
  in
  Eio.Fiber.first listen forward
```

When the client leaves, `listen` ends and `forward` is cancelled. If it was
cancelled partway through a send, the socket ends, as
[Closing a socket](#closing-a-socket) says; the client has gone anyway.

## Testing and OpenAPI

- `Spindle.Test.websocket app protocol "/echo" f` opens a socket as a browser
  does and runs `f` on the client's end, with no port. A route that refuses
  the upgrade answers `Refused`. Keep-alive never fires in a test.
- The OpenAPI document lists the route as a `101`, with each side's schema
  under `x-websocket`; the Zod module types it as
  `{ websocket: { client, server } }`.

To speak another protocol over a connection, see `Spindle.Response.takeover`
and `Spindle.Websocket.run_server` / `run_client` in the reference.
