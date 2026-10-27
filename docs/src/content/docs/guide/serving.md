---
title: Server configuration and shutdown
---

`Spindle.serve env routes` is the whole server. Anything the routes need --
a database pool, a client -- is made first, inside `Eio_main.run`, and
supplied as a [resource](/spindle/tutorial/dependencies/#resources):

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Spindle_sqlite.Pool.run env "app.db" @@ fun pool ->
  Spindle.serve env ~port:3000
    ~limits:(Spindle.Server.Limits.make ~max_connections:1024 ())
    ~resources:[ Spindle.Dep.resource db pool ] routes
```

By default it serves on `localhost:8080`, on every CPU core, stops cleanly
on SIGTERM or SIGINT, and prints where it listens. Every setting is an
optional argument, and the limits on clients are one of them, `~limits`.

Two kinds of mistake stop the server before it listens:

- A route table that cannot be right -- two routes answering one URL, say
  -- raises `Invalid_argument`, naming the route. So does a limit out of
  its range, where `Limits.make` is called.
- A `Static.directory` or a `Files.directory` that cannot be read, a
  resource a route reads that `~resources` does not hold, a signed or
  encrypted cookie a route reads with no `~keys`, or a host and port it
  cannot listen on, is one line saying why -- in the log, or on stderr
  where the program set none up -- and the program exits with status 1:

```
cannot listen on localhost:8080: another program holds port 8080 on 127.0.0.1
```

A port is bound on every address the host names or on none, so a server
never starts on IPv6 alone beside another program holding the port on IPv4.

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
[the client's IP address](/spindle/guide/cookies/#the-clients-ip-address).

## Using every core

`~domains` is how many OCaml domains serve, one per core by default. A
handler runs beside handlers on other domains, so whatever it shares must be
safe to share: immutable, an `Atomic`, an `Eio.Mutex`. An application that
is not serves with `~domains:1`. [Multicore and shared
state](/spindle/guide/domains/) has the details.

## Limits

Every wait on a client is bounded, so a slow or stuck client cannot hold a
connection for ever. The defaults suit an ordinary API; change one only for
a reason. They are one value, `~limits`, made by `Spindle.Server.Limits.make`,
which takes each by its name and keeps the rest at their defaults.

| Limit | Default | When it is passed |
|---|---|---|
| `max_body` | 1 MiB | the body is `413` |
| `body_budget` | 64 MiB | bodies held at once, across all requests; past it `503 busy` |
| `max_header_bytes` | 16 KiB | the head is `431` (`414` for a long request line) |
| `head_timeout` | 10 s | a head still arriving is `408` |
| `idle_timeout` | 60 s | an idle connection is closed |
| `body_timeout` | 20 s | a body gets 20 s, plus one second for every `min_body_rate` (500) bytes received; one that falls behind is closed |
| `handler_timeout` | 60 s | a handler still running is cancelled and answered `503 timed_out`; time spent waiting on its body is not counted |
| `send_timeout` | 30 s | a client that stops reading the answer is closed |
| `max_connections` | 512 | connections held at once, per address; the rest wait in `backlog` (128) |
| `discard_limit` | 64 KiB | a body a route left unread is read and dropped up to it; with more left, the connection is closed |
| `linger` | 1 s | a closing connection's last bytes are read and dropped, so the client gets the answer |
| `drain` | 10 s | requests in flight at shutdown are cancelled ([below](#graceful-shutdown)) |

A wait is an `Mtime.Span.t`, named for what it bounds:
`Limits.make ~send_timeout:Mtime.Span.(60 * s) ()`. A timeout of zero is
refused where the limits are made, since the server would wait for nothing;
only `drain` and `linger` may be zero.

A route has its own `max_body`, `body_timeout`, `min_body_rate` and
`handler_timeout` in place of these, by the same names, and keeps the server's where it gives none:
`Spindle.post ~limits:(Spindle.Route.Limits.make ~max_body:(64 * 1024 *
1024) ()) ...` ([large bodies](/spindle/tutorial/bodies/#large-bodies)). The
rest act before a route is chosen, between requests or on the whole server,
so they are the server's alone.

`handler_timeout` is the one limit on your own code rather than the
client's. A handler stuck on something that never comes -- a row lock, an
upstream with no deadline of its own -- would otherwise hold its connection
and whatever it took from a pool for good, until the pool is empty and
routes that never touch it stop answering too. Past the limit its handler
is cancelled, with everything it started: a database statement in flight
closes its connection, so its transaction ends with nothing kept. Work
handed to `Background` is not cancelled. A route that legitimately runs
longer, an export say, gives its own:
`Spindle.post ~limits:(Spindle.Route.Limits.make ~handler_timeout:Mtime.Span.(5 * min) ()) ...`.
A stream or a socket runs after its answer, so the limit is over by then.

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
3. Requests in flight get `drain` (10 s, a [limit](#limits)) to finish, each
   answered with `Connection: close`. A stream of known length -- a file --
   counts as one until its last byte is sent; an event stream does not,
   since only `~on_stop` ends it.
4. Whatever is left is cancelled, and `serve` returns.

A second signal ends the process at once. To stop on something other than
a signal, pass your own promise as `~stop`.

If your routes publish to a
[`Spindle.Broadcast`](/spindle/guide/sse/#broadcasting-to-many-clients) --
here called `hub` -- close it in `~on_stop`, so every stream reading it ends
and the drain can finish:

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
| `~resources` | what the routes read that the program holds -- a pool, a client -- made where it starts ([Resources](/spindle/tutorial/dependencies/#resources)) |
| `~keys` | what signed and encrypted cookies are sealed under, from a secret the program reads ([Signed and encrypted cookies](/spindle/guide/cookies/#signed-and-encrypted-cookies)) |
| `~middleware` | wraps every route ([Middleware](/spindle/guide/middleware/)) |
| `~refuses` | the refusal codes your middleware may answer ([Middleware](/spindle/guide/middleware/#writing-middleware)) |
| `~not_found` | answers a request no route claims ([Routes](/spindle/tutorial/routes/#how-routes-are-matched)) |
| `~trailing_slash` | `Strict` by default; `Redirect` answers `/a/` with a `308` to `/a` ([Routes](/spindle/tutorial/routes/#how-routes-are-matched)) |
| `~check_origin`, `~trusted_origins` | the cross-site check on requests that change something ([CSRF and CORS](/spindle/guide/cookies/#csrf-and-cors)) |
| `~cors` | lets other sites' pages call your routes ([CSRF and CORS](/spindle/guide/cookies/#csrf-and-cors)) |
| `~compress` | gzip for clients that accept it ([Compression](/spindle/guide/compression/)) |
| `~trusted_proxies`, `~proxy_header` | the proxies whose forwarding header is believed, and which header that is: `X_forwarded_for` (default) or `Forwarded` ([The client's IP address](/spindle/guide/cookies/#the-clients-ip-address)) |
| `~trace` | sends a span for every request ([Tracing](/spindle/tutorial/logging/#tracing)) |
| `~metrics` | counts requests and connections ([Metrics](/spindle/guide/metrics/)) |
| `~ready` | told the address once the server listens; by default it is printed to stdout |
| `~read_clock` | the clock a handler reads as `Spindle.now`; the system clock by default |

## Without Spindle.serve

A program that builds its routes at run time, or wants no signal handler,
does what `Spindle.serve` does in three steps: `App.make` the routes,
`App.start` the app, and `Server.run` the instance it answers, with every
capability passed explicitly. `App.start` takes what exists only once the
program runs -- the `~resources`, the `~keys`, the `~mono_clock` its rate
limits are timed on, and the `~fs` any `Static.directory` or
`Files.directory` is read from -- and each call is an instance of its own,
so two never share what they hold. `Server.serve_on` serves on sockets you
already listen on -- a test's, on a port the system chose.
