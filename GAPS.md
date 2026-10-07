# Spindle: known gaps

What the framework lacks, gets wrong or leaves untested -- for any
application built on it, across every library it is made of: `spindle`,
`spindle.http`, `spindle.client`, `spindle_postgres` and `spindle_cli`. What
the packages it is built on lack are theirs to say, each in its own
repository:
[wiretype](https://github.com/hyphatech/wiretype#what-it-does-not-do),
[rowtype](https://github.com/hyphatech/rowtype) and
[postgres-eio](https://github.com/hyphatech/postgres-eio).
What Spindle is and how it reads is [its README](README.md).

## What an application would want first

- **gzip is the one coding written at run time.** Brotli and zstd are
  served only where the build wrote them beside a file, since neither has an
  OCaml encoder; and a request's body is never decompressed -- one that says
  `Content-Encoding` is read as the bytes it is.
- **Nothing measuring a domain.** There is no lag probe, and no
  CPU offload beyond what an application writes with an
  `Eio.Executor_pool`
  ([Domains](docs/guide/domains.md)).
- **A span is sent once.** `Spindle_client.Otlp` drops a batch the collector
  refused or never answered rather than send it again, so a collector that
  restarts loses what was sent while it was down; and only JSON over HTTP,
  never protocol buffers or gRPC. A WebSocket, the server's or the client's,
  records no span, since a socket lives far longer than the request that
  opened it.
- **Routes are listed one at a time.** Nothing groups them under a shared
  prefix, tags or refusal codes; an application maps a function over its
  list.
- **HTTP/1.1 alone, and no TLS in the process.** No HTTP/2 or HTTP/3, and a
  certificate is a proxy's to hold: a server speaks plain HTTP/1.1 behind
  one.
- **Metrics are read, never pushed.** They are at `/metrics` for a scraper
  to read; nothing sends them to a collector as `Spindle_client.Otlp` sends
  spans.
- **No localisation of the framework's own sentences.** `Refusal.not_found`
  and its kin are English and fixed, with no way to supply their words in
  another language.
- **Not in opam-repository.** The packages are pinned from this repository,
  as are the Hypha libraries under them ([README](README.md#install)), and
  the documentation site is built (`make docs`) but published nowhere; its
  Install page is written as the packages will be installed.
- **OCaml 5.5 needs a preview of `ocamlfind`.** `logs`, `mtime` and `uunf`
  are built with it, and its stable release refuses 5.5, so the Install page
  names OCaml 5.4, on which everything installs from opam as released.
- **The guide is the README's words moved.** The tutorial was written for a
  newcomer; the pages under *Going further* are the orientation the README
  was, a page a subject, not yet written as a tutorial is.

## WebSockets

The requirements of RFC 6455 either end meets are `test_websocket_rfc`'s
rows; these are what it leaves out.

- **No compression.** `permessage-deflate` (RFC 7692), the one extension in
  common use, is neither offered nor agreed: a client that offers it is
  answered without it, and the client refuses a server that names it.
- **One subprotocol per route.** A protocol names one, and a server refuses
  a client that did not offer it; choosing among several a client offers,
  or serving more than one on a route, is not there.
- **A message is read whole.** A fragmented message is put together up to
  `max_message` before `receive` answers; nothing reads one as it arrives,
  which a socket carrying files would want.
- **Described as far as OpenAPI goes.** A socket is a `101` and
  `x-websocket`, an extension of ours; AsyncAPI, the one format that
  describes a socket fully, is not written.
- **No WebSocket over HTTP/2** (RFC 8441), since Spindle speaks HTTP/1.1.

## Events and files

- **One range to an answer.** A request for several (`multipart/byteranges`)
  is answered whole, as RFC 9110 lets a server; a download that resumes
  asks for one.


## Domains and processes

- **An application on `Broadcast`, `Alarm` or `Rate` is one process.** Each
  holds its state in memory, so a second process would neither hear the
  first's events, nor know its alarms, nor count the calls it let through. There is no second backend -- Redis, say --
  to share them, and no signature one would meet.

## HTTP

The rows `test_http_rfc` holds are the requirements Spindle meets, and the
field values `spindle_http` reads are rows too; a requirement it does not
meet is a line here, and there is none today.

## Speed

- **A request costs more above the HTTP layer than it needs to.**
  Profiled at its peak with logging off, reading and
  writing the message is not most of it, and the profile says who asked
  for every word above it: the route, the
  request and its id, and a cancellation context for every read against
  the deadline. None of it is what strictness costs.
- **A request keeps more alive across its reads and writes than it
  needs.** Its record, its closures, its head and framing reader and its
  context are all held while it waits on the socket, which is why a
  domain's minor heap has to be raised to hold the requests in flight;
  less of each would let the default do.

## Postgres

- **An instant before year 1 is refused.** `Spindle_postgres.instant` writes
  one as Ptime's earliest, in its year 0, which the column refuses as it is
  written: a statement carrying one fails rather than storing the nearest.

## Calling another server

- **The client follows no redirect, goes through no proxy, keeps no
  cookie, and neither compresses a request's body nor decompresses an
  answer.** A request's body is one string; an answer is read whole up to
  `?max_body`, or as it arrives by `stream`.
