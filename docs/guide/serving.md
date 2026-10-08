# Server configuration and shutdown

`Spindle.serve env routes` is the whole server. Anything the routes need --
a database pool, a client -- is made first, inside `Eio_main.run`:

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Spindle_postgres.Pool.run env database @@ fun pool ->
  Spindle.serve env ~port:3000 ~max_connections:1024
    ~on_stop:(fun () -> Spindle.Broadcast.close hub)
    (routes ~pool)
```

By default it serves on `localhost:8080`, on every CPU core, stops cleanly
on SIGTERM or SIGINT, and prints where it listens. Every setting is an
optional argument.

A route table that cannot be right -- two routes answering one URL, say --
raises `Invalid_argument` before the server listens, naming the route.

## Where it listens

| `~host` | Listens on |
|---|---|
| `"localhost"` (default) | `127.0.0.1` and `[::1]`, this machine only |
| `"0.0.0.0"` or `"::"` | every interface, IPv4 and IPv6 |
| an address, e.g. `"10.0.0.5"` | that address |
| a name | every address it resolves to |

In a container, a pod or on a hosting platform, use `~host:"0.0.0.0"`.
Listening beyond your machine is always written down; a laptop never serves
the network it happens to be on.

TLS is the one thing Spindle leaves to a proxy or the platform. Behind one,
name it in `~trusted_proxies` (an address or a CIDR range) so the client's
real address and request id are read from its headers -- see
[the client's IP address](cookies.md#the-clients-ip-address).

## Using every core

`~domains` is how many OCaml domains serve, one per core by default. A
handler runs beside handlers on other domains, so whatever it shares must be
safe to share: immutable, an `Atomic`, an `Eio.Mutex`. An application that
is not serves with `~domains:1`. [Multicore and shared state](domains.md) has the details.

## Limits

Every wait on a client is bounded, so a slow or stuck client cannot hold a
connection for ever. The defaults suit an ordinary API; change one only for
a reason.

| Argument | Default | When it is passed |
|---|---|---|
| `max_body` | 1 MiB | the body is `413` |
| `body_budget` | 64 MiB | bodies held at once, across all requests; past it `503 busy` |
| `max_header_bytes` | 16 KiB | the head is `431` (`414` for a long request line) |
| `head_timeout_s` | 10 | a head still arriving is `408` |
| `idle_timeout_s` | 60 | an idle connection is closed |
| `body_timeout_s` | 20 | a body's allowance, which grows a second for every `min_body_rate` (500) bytes; a body that falls behind is closed |
| `send_timeout_s` | 30 | a client that stops reading the answer is closed |
| `max_connections` | 512 | connections held at once, per address; the rest wait in `backlog` (128) |

A route that takes large uploads reads its body as a stream, with a limit of
its own ([dependencies](../tutorial/dependencies.md#large-bodies)).

Keep `max_connections` under the process's file descriptor limit
(`ulimit -n`): every open stream and WebSocket holds a connection.

## Graceful shutdown

On the first SIGTERM or SIGINT:

1. `~on_stop` runs. End your streams here -- an event stream or a broadcast
   never ends on its own.
2. The server stops accepting connections.
3. Requests in flight get `~drain_s` (10 seconds) to finish, each answered
   with `Connection: close`.
4. Whatever is left is cancelled, and `serve` returns.

A second signal ends the process at once. To stop on something other than
a signal, pass your own promise as `~stop`.

## What the server handles for you

Spindle reads and writes HTTP/1.1 itself, and every requirement of RFC 9112
and RFC 9110 it meets is a test. Among them:

- A malformed request -- a bad head, a missing or doubled `Host`, a body
  framed two ways -- is `400` and its connection closed, so nothing can
  smuggle a second request inside the first.
- A body the route did not read is discarded before the next request on the
  connection.
- `Expect: 100-continue` is answered only by a route that reads its body,
  and never for a body over `max_body`.
- `Content-Length`, `Transfer-Encoding` and `Connection` are the server's
  to write; a route that sets one itself answers `500`.
- HTTP/1.0 clients are answered as HTTP/1.0.

## Without Spindle.serve

`Spindle.serve` is three steps, which a program that builds its routes at
run time, or wants no signal handler, takes itself: `App.make` the routes,
`App.start` the app (which reads any `Static.directory`), and `Server.run`
it with every capability passed explicitly. `Server.serve_on` serves on
sockets you already listen on -- a test's, on a port the system chose.
