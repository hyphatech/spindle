# Serving, and stopping

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Spindle_postgres.Pool.run env database @@ fun pool ->  (* what the routes need, first *)
  Spindle.serve env ~port:3000 ~max_connections:512
    ~on_stop:(fun () -> Spindle.Broadcast.close hub)
    (routes ~pool)
```

`Spindle.serve env routes` makes the app and serves it, taking the network,
the domain manager and both clocks from Eio's environment: `now` is
`Spindle.epoch_ms` of its clock, the port is `8080`, SIGTERM and SIGINT stop
it cleanly, and it prints where it listens. Every other argument is
`App.make`'s or `Server.run`'s, of the same name and default. It leaves
`Eio_main.run` to the program, because anything the routes need -- a pool, a
client -- is made from `env` first; a program grows by adding lines above
`serve`, never by rewriting around it. A route table `App.make` refuses
raises `Invalid_argument` before it listens: routes are constants written
in source. `Server.run` is the same thing with every capability given
explicitly, for a program that builds its routes at run time or wants no
signal handler, and `Server.serve_on` serves on sockets the caller already
listens on -- a test's, on a port the system chose.

- **Every core, unless told.** `domains` defaults to
  `Domain.recommended_domain_count ()`: the calling domain and the rest
  started through `domain_mgr`, which is a capability like `net`. Each domain
  accepts on every address and keeps what it accepted, and every limit
  below is one limit across all of them. Eio's own `run_server` is not what
  runs them: it adds its domains per address, and runs a body of its own on
  each, with nowhere for a domain's switch or sweep.

- **Where it listens is `host` and `port`**, as a name or an address:
  `localhost` (the default, both loopback addresses whatever the resolver
  says), an address such as `"10.0.0.5"`, a wildcard -- `"0.0.0.0"` or
  `"::"`, every interface of both families, what a container, a pod or a
  hosting platform needs -- or a name, every address of which is bound.
  `localhost` is the default so that listening further is written down where
  the server starts, and a laptop never serves the network it happens to be
  on. A wildcard binds the IPv6 one, which takes IPv4 as well on most hosts,
  and the IPv4 one beside it where it does not. A name the resolver does not
  know stops the server before it listens, as a taken port does. The
  server's own limits hold with no proxy in front at all; TLS is the one
  thing left to a proxy or the platform.
- **The connection loop is Spindle's**, and so is every byte it reads, all of
  it through `spindle_http`. A head RFC 9112 forbids -- a line folded onto
  the one before it, whitespace before a colon, a name that is not a token, a
  bare CR or a control character -- is `400` and closed; so is an HTTP/1.1
  request without exactly one valid `Host`, any request with two, and a
  target in a form its method may not use. A request line too long to read
  is `414`, another major version than HTTP/1 is `505`, and a later HTTP/1
  minor version is answered as HTTP/1.1. A line ended by a bare LF, and an
  empty line before the request, are read, as RFC 9112 lets a server read
  them -- but not inside a chunked body, whose lines end in CRLF. The host a
  request is for is an absolute-form target's authority where it has one, and
  otherwise `Host` (`Request.host`, after a trusted proxy's
  `X-Forwarded-Host`); a host is RFC 3986's, so in brackets it is an IPv6
  address or an IPvFuture and nothing else, and `CONNECT`'s target is a host
  and a port. A method no route declares and the framework does not
  know is `501`, before the not-found answer. Each connection carries another
  request only once the last one's
  body was read to its end: what a route left unread is discarded, up to
  `discard_limit` (64 KiB), before the answer is written, and a body with
  more left than that closes the connection. A framing RFC 9112 forbids -- a
  `Transfer-Encoding` beside a `Content-Length`, two lengths, a malformed
  chunk -- is `400` and closed, because a body that ends in the wrong place
  is read as the next request; `Transfer-Encoding` is a list, so an empty
  element in it is nothing, and `chunked` named twice is `400`; a trailer
  line is a field line, and one that is not breaks the body. A request that
  says `Expect: 100-continue` is told to go ahead only by a route that reads
  its body, and never when its declared length is past `max_body` -- the
  `413` stands for the `100` -- or has no room in `body_budget` at the
  moment it would be told, when `503 busy` does; one with no body has
  nothing to be told and is served as any other.
- **The connection is the server's to describe.** An answer carries one
  `Connection` field, the server's own decision: `close` whenever it will
  close -- the client asked, the answer was `closing`, the body was left
  unfinished, the server is stopping -- `keep-alive` only to an HTTP/1.0
  client it keeps, and nothing on a kept HTTP/1.1 answer, where keeping is the
  default.
- **Every 2xx, 3xx and 4xx carries `Date`**, from `now`, as RFC 9110 §6.6.1
  asks of a server with a clock.
- **HTTP/1.0 is answered as HTTP/1.0.** A stream to it is written as it
  happens and ended by closing the connection, since it has no chunked
  coding; it is sent no `100 Continue`, since it has no 1xx; it is never
  switched to another protocol; and a request of its that carries
  `Transfer-Encoding` is answered and then closed, since whoever framed it
  cannot be trusted to have ended it where it ends.
- **A connection the server closes is closed in stages**, as RFC 9112 §9.6
  advises: its own side first, then what the client is still sending read
  and dropped -- up to `discard_limit`, for at most `linger_s` (1) -- and then
  the socket. Closing at once with unread bytes on it has the kernel answer
  them with a reset, which can reach the client before the answer it was
  written after: a `413` above all, which is said while the body is still
  arriving.
- **Limits, each an optional argument:** a body past `max_body` (1 MiB) is
  `413`, a chunked body's extensions counted toward it; the bodies held at
  once share `body_budget` (64 MiB), counted as their bytes arrive and not as
  a length claims and given back when the route returns, before its answer
  is written, past which a request is `503 busy` and closed; a head past `max_header_bytes` (16 KiB)
  is `431`; a write the client does not read for `send_timeout_s` (30)
  closes the connection, and a stream ends as its client having stopped
  reading. Every wait on a client is bounded, because a client that stops is
  otherwise a fiber and a connection slot held for as long as the process
  lives. `clock` is the monotonic clock they are measured on.
- **A connection has one deadline**, moved as it makes progress, and every
  read of it and every flush of an answer runs against it -- moving it is a
  write to a field, not a timer. One sweep per domain looks at the deadline
  of every connection that domain accepted, a tenth of the shortest of these
  limits apart
  (once a second at the defaults), so a deadline passes up to that late:
  a timer per connection had to sleep again whenever a request moved its
  deadline earlier, which every request does, and that was a large part of
  what a request cost.
  While an answer is written it is `send_timeout_s` from the last byte the
  client took, so a large answer to a slow reader is never cut off for being
  slow. Between requests it is
  `idle_timeout_s` (60) from the last answer, and then the connection is
  closed; for a head, `head_timeout_s` (10) from its first byte, and then it
  is `408`; for a body, `body_timeout_s` (20) from when it is first read,
  moved a second later for every `min_body_rate` (500) bytes that arrive --
  what came in with the head included -- and
  a body that falls behind is unreadable and its connection closed. A body
  must keep up a rate once its allowance is spent, because a wait re-armed on
  every byte let a client sending one a minute hold its connection for as
  long as its length allowed. The figures are a floor no ordinary upload is
  near -- a megabyte at the floor still arrives in about half an hour -- and
  they make holding a slot cost bandwidth rather than nothing; an address
  that pays it is the per-address limit's to stop, which is a proxy's. The
  deadline is armed only while the client is being waited for, so a
  handler's own time is never counted against it, and a takeover's reads
  are the route's to bound.
- **`max_connections`** (512, per address, however many domains accept on
  it) is how many connections are held at once; the rest wait in the
  kernel's backlog. Every open stream holds one, so it is also how many
  streams a process carries. Keep it under the process's
  descriptor limit: Eio takes the slot before it calls `accept`, so the cap is
  what keeps `accept` from failing at that limit -- a failure that would
  cancel every open connection with it.
- **`stop`** ends the server politely: `on_stop` runs -- where the
  application ends its streams, which never end on their own -- the addresses
  stop accepting, the requests being answered get `drain_s` (10) to finish,
  each answer saying `Connection: close`, and then whatever is left, on
  every domain, is cancelled and `run` returns. The drain counts requests, not connections, so
  a proxy's idle keep-alives do not hold it open.
- **`stop_on_signals`** is a promise resolved by the first SIGTERM or SIGINT.
  Nothing installs a handler unless it is called, and after the first signal
  both go back to their default, so a second one ends the process at once.
