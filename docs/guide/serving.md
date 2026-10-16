# Server configuration and shutdown

`Spindle.serve env routes` is the whole server. Anything the routes need --
a database pool, a client -- is made first, inside `Eio_main.run`, and
supplied as a [resource](../tutorial/dependencies.md#resources):

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Spindle_postgres.Pool.run env database @@ fun pool ->
  Spindle.serve env ~port:3000 ~max_connections:1024
    ~resources:[ Spindle.Dep.resource db pool ] routes
```

By default it serves on `localhost:8080`, on every CPU core, stops cleanly
on SIGTERM or SIGINT, and prints where it listens. Every setting is an
optional argument.

Three mistakes stop the server before it listens:

- A route table that cannot be right -- two routes answering one URL, say
  -- raises `Invalid_argument`, naming the route. So does a limit out of
  its range.
- A `Static.directory` or a `Files.directory` that cannot be read, or a
  resource a route reads that `~resources` does not hold, logs an error
  saying why, and the program exits with status 1.
- A port already in use, or a `~host` name the resolver does not know,
  raises Eio's I/O error.

## Where it listens

| `~host` | Listens on |
|---|---|
| `"localhost"` (default) | `127.0.0.1` and `[::1]`, this machine only |
| `"0.0.0.0"` or `"::"` | every interface, IPv4 and IPv6 |
| an address, e.g. `"10.0.0.5"` | that address |
| a name | every address it resolves to |

In a container, a pod or on a hosting platform, use `~host:"0.0.0.0"`.
Serving beyond your machine has to be asked for in code, so a laptop never
serves the network it happens to be on.

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
| `head_timeout` | 10 s | a head still arriving is `408` |
| `idle_timeout` | 60 s | an idle connection is closed |
| `body_timeout` | 20 s | a body gets 20 s, plus one second for every `min_body_rate` (500) bytes received; one that falls behind is closed |
| `send_timeout` | 30 s | a client that stops reading the answer is closed |
| `max_connections` | 512 | connections held at once, per address; the rest wait in `backlog` (128) |

A wait is an `Mtime.Span.t`, named for what it bounds:
`~send_timeout:Mtime.Span.(60 * s)`. A timeout of zero is refused, since
the server would wait for nothing; only `~drain` and `~linger` may be zero.

A route that takes large uploads reads its body as a stream, with a limit of
its own ([large bodies](../tutorial/bodies.md#large-bodies)).

Keep `max_connections` under the process's file descriptor limit
(`ulimit -n`): every open stream and WebSocket holds a connection, and a
file being sent holds a descriptor as well. Past the limit a connection
waits: the server logs the failed accept at `warning` and tries again 10 ms
later, serving the connections it has meanwhile.

## Graceful shutdown

On the first SIGTERM or SIGINT:

1. `~on_stop` runs. End your streams here -- an event stream or a broadcast
   never ends on its own.
2. The server stops accepting connections.
3. Requests in flight get `~drain` (10 s) to finish, each answered
   with `Connection: close`. A stream of known length -- a file -- counts
   as one until its last byte is sent; an event stream does not, since only
   `~on_stop` ends it.
4. Whatever is left is cancelled, and `serve` returns.

A second signal ends the process at once. To stop on something other than
a signal, pass your own promise as `~stop`.

If your routes publish to a [`Spindle.Broadcast`](sse.md#broadcasting-to-many-clients)
-- here called `hub` -- close it in `~on_stop`, so every stream reading it
ends and the drain can finish:

```ocaml
Spindle.serve env ~on_stop:(fun () -> Spindle.Broadcast.close hub) routes
```


## What the server handles for you

Spindle reads and writes HTTP/1.1 itself, and every requirement of RFC 9112
and RFC 9110 it meets is a test, as is every one of RFC 9111's
`Cache-Control` and RFC 7239's `Forwarded`. Among them:

- A malformed request -- a bad head, a missing, empty or doubled `Host`, a
  body framed two ways -- is `400` and its connection closed, so nothing can
  smuggle a second request inside the first.
- A body the route did not read is discarded before the next request on the
  connection.
- `Expect: 100-continue` is answered only by a route that reads its body,
  and never for a body over `max_body`.
- The server writes the fields that say how an answer is framed --
  `Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`,
  `Upgrade`, `TE` and `Trailer` -- and the ones it works out itself:
  `Content-Type` from the route's `Returns`, `Set-Cookie` from its cookies,
  `Date` and `X-Request-Id`. A route that sets any of them as a header
  answers `500`.
- HTTP/1.0 clients are answered as HTTP/1.0.

The same holds beyond HTTP itself: WebSockets are tested against RFC 6455,
a form's multipart body against RFC 7578 and RFC 2046, and Structured
Fields against RFC 9651's published test suite, run whole.

## Every other argument

`Spindle.serve` also takes these, each covered on its own page:

| Argument | What it does |
|---|---|
| `~resources` | what the routes read that the program holds -- a pool, a client -- made where it starts ([Resources](../tutorial/dependencies.md#resources)) |
| `~middleware` | wraps every route ([Middleware](middleware.md)) |
| `~codes` | the refusal codes your middleware may answer ([Middleware](middleware.md#writing-middleware)) |
| `~not_found` | answers a request no route claims ([Routes](../tutorial/routes.md#how-routes-are-matched)) |
| `~trailing_slash` | `Strict` by default; `Redirect` answers `/a/` with a `308` to `/a` ([Routes](../tutorial/routes.md#how-routes-are-matched)) |
| `~check_origin`, `~trusted_origins` | the cross-site check on requests that change something ([CSRF and CORS](cookies.md#csrf-and-cors)) |
| `~cors` | lets other sites' pages call your routes ([CSRF and CORS](cookies.md#csrf-and-cors)) |
| `~compress` | gzip for clients that accept it ([Compression](compression.md)) |
| `~trusted_proxies`, `~proxy_header` | the proxies whose forwarding header is believed, and which header that is: `X_forwarded_for` (default) or `Forwarded` ([The client's IP address](cookies.md#the-clients-ip-address)) |
| `~trace` | sends a span for every request ([Tracing](../tutorial/logging.md#tracing)) |
| `~metrics` | counts requests and connections ([Metrics](metrics.md)) |
| `~ready` | told the address once the server listens; by default it is printed to stdout |
| `~read_clock` | the clock a handler reads as `Spindle.now`; the system clock by default |
| `~discard_limit` | 64 KiB: how much of a body a route left unread is read and dropped; with more left, the connection is closed |
| `~linger` | 1 s: how long a closing connection's last bytes are read and dropped, so the client gets the answer |

## Without Spindle.serve

A program that builds its routes at run time, or wants no signal handler,
does what `Spindle.serve` does in three steps: `App.make` the routes,
`App.start` the app (which takes the `~resources` and the `~mono_clock` its
rate limits are timed on, and reads any `Static.directory` or
`Files.directory`), and `Server.run` it with every capability passed
explicitly. `Server.serve_on` serves on sockets you already listen on -- a
test's, on a port the system chose.
