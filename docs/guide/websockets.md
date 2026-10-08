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
  `Lost` or `Unreadable`.

A plain request to the route is refused, and so is an upgrade from another
site's page, since the browser sends that page's cookies:

```sh
curl -i localhost:8080/echo
```

```text
HTTP/1.1 426 Upgrade Required
upgrade: websocket

{"error":"upgrade_required","message":"This address opens a WebSocket, and nothing else."}
```

## Connecting as a client

```ocaml
--8<-- "websocket_client.ml"
```

```sh
dune exec examples/websocket_client.exe
```

```text
heard: hello
heard: is anybody there
heard: goodbye
```

`Spindle_client.websocket client protocol url f` opens a `ws://` or `wss://`
URL, runs `f` on the socket and closes it when `f` returns. It answers `f`'s
result, or `Failed` (the handshake could not be made), `Refused` (the server
answered without a `101`, with that answer) or `Ended` (how the socket
ended). `~timeout_s` bounds the handshake and each write.

Both programs declare the same protocol. When the two ends are separate
programs, put it in a library both link so they cannot drift apart.

## Closing a socket

How the handler's loop ended is the close code:

| The handler | Close code |
|---|---|
| returns `Ok` | 1000 |
| got a message its description could not read | 1007 |
| raised (logged as a bug) | 1011 |

To close with another code, call `Ws.close ~code ~reason ws` and return.
Nothing raises into your handler: a socket whose peer has gone answers its
next `receive` or `send` with an error.

The framework handles the rest of the protocol for you:

- ping and pong: a ping after `~keep_alive_s` (15) seconds of silence, and a
  peer silent for twice that is `Lost`;
- a message over `~max_message` (1 MiB) closes the socket with 1009, and one
  of a kind the socket does not carry with 1003;
- a stopping server closes every socket with 1001;
- one log line when a socket ends: how long it lived and why.

`~keep_alive_s` and `~max_message` are arguments of
`Spindle.Returns.websocket` and `Spindle_client.websocket`.

## Broadcasting to many sockets

To send one message to many sockets, encode it once with
`Ws.encode (Ws.server protocol) value` and send that to each with
`Ws.send_encoded`. A [`Spindle.Broadcast`](streams.md) of sockets carries
encoded messages.

## Testing and OpenAPI

- `Spindle.Test.websocket app protocol "/echo" f` opens a socket as a browser
  does and runs `f` on the client's end, with no port. A route that refuses
  the upgrade answers `Refused`. Keep-alive never fires in a test.
- The OpenAPI document lists the route as a `101`, with each side's schema
  under `x-websocket`; the zod module types it as
  `{ websocket: { client, server } }`.

To speak another protocol over a connection, see `Spindle.Response.takeover`
and `Spindle.Websocket.run_server` / `run_client` in the reference.
