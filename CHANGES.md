# Changes

## Unreleased

- Breaking: `Spindle_http.Head.Response.read` answers a
  `Head.Response.error`, `Closed` or `Malformed of string`, where it
  answered the polymorphic `` `Closed `` and `` `Malformed ``: one shape
  for the same event as `Head.Request.read`'s `Head.error`, whose
  `Closed` it matches.

- Breaking: a Structured Field date is `Spindle_http.Structured.Date of
  Ptime.t`, where it was an `int` of seconds since 1970, since every
  instant is a `Ptime.t`. A date outside the years 0 to 9999, which RFC
  9651 allows and no `Ptime.t` holds, is refused when read, as its
  published suite lets a parser do; one written with a fraction of a
  second is written in the second it is in.

- Breaking: a `Spindle_client` answer's `status` -- `response`'s and
  `answer`'s -- is a `Spindle_http.Status.t`, as a route answers with
  and `Head.Response.t` holds, where it was an `int`: match `` `OK ``,
  or take the number with `Spindle_http.Status.to_int`.

- Breaking: `Spindle_client.error` says whether the request went out.
  `Unreachable` is gone: a request that never left -- no address, a
  refused connection, failed TLS, a URL or field the client cannot
  write -- is `Unsent`, and one that went and was not answered whole --
  closed under it, cut short, unreadable, too long -- is `Unanswered`,
  so a caller knows when a `POST` can be sent again. `Timeout` may be
  either, and is to be taken as `Unanswered`. A client span's failure
  says `unsent` or `unanswered` where it said `unreachable`.

- A WebSocket message's buffer grows as its bytes arrive, where it was
  made as large as its first frame declared: fourteen bytes from a peer
  held as much memory as `max_message` allows, a mebibyte by default,
  for as long as the peer cared to send nothing more.

- `Spindle_client` sends a URL's path and query as the URL wrote them,
  where it decoded them and encoded them again: `%3B` went as `;`, `%2F`
  as `/` and `+` as `%20`, so a signed URL reached its server as one it
  did not sign.

- A WebSocket handler that raises is logged once, at `error`, with what
  was raised and where: a server's socket on its line saying how it
  ended, where `spindle.http` also logged a line of its own, and a
  client's on the line `Spindle_client.websocket` writes when its socket
  ends, which now says where it went and how long it lived.
  `Spindle_http.Websocket.run_server` and `run_client` log nothing of a
  raise they pass on.

- A request whose `Expect` lists `100-continue` among other elements, or
  in a second `Expect` field, is sent `100 Continue`, where only a field
  that was `100-continue` alone was: `Expect` is a list (RFC 9110
  §10.1.1), and is read as one.

- `Spindle_client` opens every connection through the `net` it is
  given, with `Eio.Net.connect`, where it opened its sockets with `Unix`
  itself, so a test can give it `Eio_mock.Net`. Each connection lives on
  a switch of its own, so one that fails to connect still leaves no
  socket behind. A socket with no descriptor beneath it, as a mock
  network's, is closed after its call and never kept, since the client
  could not tell that the server closed it.

- A server whose `accept` fails -- out of file descriptors or memory, or
  a connection reset before it was taken -- logs it at `warning` and
  accepts again 10 ms later, where the failure ended the server and
  cancelled every connection it held.

## 0.3.1 (2026-10-12)

- `Spindle_http.Instant.sleep` blocks a domain or a thread no Eio loop
  runs for an `Mtime.Span.t`, where `Unix.sleepf` takes a float of
  seconds.

## 0.3.0 (2026-10-11)

- Breaking: every instant is a `Ptime.t`, where it was an `int` of
  milliseconds since 1970 that said neither its unit nor that it was a
  time. `Spindle.now` is a `Ptime.t Dep.t`, and so is what `Request.now`
  answers; the `~now` that `Spindle.serve`, `Server.run`,
  `Server.serve_on` and `Request.make` take is a `unit -> Ptime.t`, and
  `Spindle.epoch_ms` is `Spindle.clock_now`, the clock's time as one.
  `Test.call`, `Test.Browser.call`, `Test.events` and `Test.websocket`
  take `?now:Ptime.t`, `Ptime.epoch` unless given. `Session.entry`'s
  `created_ms`, `seen_ms` and `expires_ms` are `created`, `seen` and
  `expires`, and `Session.find`, `start`, `renew`, `update` and `sweep`,
  a store's `sweep` and `Cookie.Named.unseal` take `~now:Ptime.t`.
  `Codec.instant` is a `Ptime.t Codec.t`, and `Conditional`'s validators,
  and so a file's `Last-Modified`, hold a `Ptime.t`. In `spindle.http`,
  `Date.parse` is `now:Ptime.t -> string -> Ptime.t option` and
  `Write.date` writes a `Ptime.t`; a trace's span holds `start : Ptime.t`
  and `duration : Mtime.Span.t`, where it held `start_ns` and `end_ns`.
  `Spindle_postgres.instant` is gone: `Rowtype.instant` reads and writes a
  `Ptime.t`. Each is written as it was -- an HTTP date, an RFC 3339 JSON
  string, a `timestamptz`, OTLP's nanoseconds -- where it crosses a wire.

- Breaking: every duration is an `Mtime.Span.t` named for what it bounds,
  where it was a float of seconds, or an int of milliseconds, named for its
  unit: a wait in the wrong unit no longer compiles. Write
  `~send_timeout:Mtime.Span.(60 * s)`. `Spindle.serve`, `Server.run` and
  `Server.serve_on` take `?head_timeout`, `?idle_timeout`,
  `?body_timeout`, `?send_timeout`, `?linger` and `?drain`, where each
  ended in `_s`, and refuse a timeout of zero. `Returns.events`,
  `Returns.websocket`, `Response.events` and `Spindle_http.Websocket`'s
  `run_server` and `run_client` take `?keep_alive`; `Response.stream`'s
  keep-alive is `{ quiet; filler }`, and `Response.connection` and
  `Spindle_http.Connection.t` hold `send_timeout`. `Spindle_client`'s
  `create` and `run` take `?timeout` and `?idle_timeout`, where they took
  `?timeout_s` and `?idle_s`; `call`, `stream`, `events` and `websocket`
  take `?timeout`, `stream` and `events` `?read_timeout`, and `websocket`
  `?keep_alive`; and `Spindle_client.Timeout` carries the
  `Mtime.Span.t` that passed. `Alarm.create` takes `?slack` and
  `Alarm.set` `~after`, where they took `?slack_ms` and `~in_ms`.
  `Rate.create` takes `~per`, the span its `~limit` is counted over, where
  it took `~per_s`, and refuses a `~per` of zero. `Session.create` takes
  `~idle` and `~absolute`, where it took `~idle_s` and `~absolute_s`.
  `spindle_postgres`'s `connect`, `Pool.create` and `Pool.run` take
  `?statement_timeout`, `?idle_in_transaction_timeout`, `?connect_timeout`
  and `?timeout`, `Pool.create` and `Pool.run` `?wait`, `?max_lifetime`
  and `?idle_check` too, and `Pool.use`, `query` and `transaction`
  `?wait`. Every default is the same length as before.

- `Spindle.until ~now deadline` is how long until an instant: the span
  from `now` to it, rounded up to the nanosecond, and zero once it has
  passed, since a wait cannot be negative -- what an `Alarm` is set for,
  `~after:(Spindle.until ~now deadline)`. `Spindle_http.Instant` has it,
  and an instant read from a clock and an instant a span on.

- In `spindle_postgres`, a statement's and an idle transaction's bounds
  are written to Postgres in whole milliseconds, rounded up, so a span
  under a millisecond is still a bound; a span of zero lifts one, as
  Postgres's `0` does.

- A number written into a message for another to read stays a whole
  number in the message's unit, labelled with it: `Refusal.rate_limited
  ~retry_after_s` and `Refusal.busy ?retry_after_s`, `Cors.make
  ?max_age_s`, `Cookie.make ?max_age_s`, `Cookie.signed` and
  `Cookie.encrypted`'s `~max_age_s`, `Event.retry ~ms` and a read event's
  `retry_ms`. A session's cookie's `Max-Age` is its absolute limit in
  whole seconds, rounded up, so the cookie outlives the session.

- `spindle` asks for wiretype 0.3.0 and depends on ptime, and
  `spindle_postgres` for rowtype 0.4.0 and postgres-eio 0.3.0, each pinned
  at that tag, so what changed there reaches a program through them.
  Breaking: a program that uses one of them itself moves with it --
  wiretype's `instant` is a `Ptime.t`, its `duration` an `Mtime.Span.t` and
  its `dict` labels `~key` and `~value`; rowtype-postgres's durations are
  `Mtime.Span.t`s named for what they bound.

- A log line's time is read from the system's clock through ptime, and a
  file's entity tag is made from its time to the nanosecond as ptime holds
  it, so a file's tag may change once, a cache asking for it again.

- Breaking: `Refusal.rate_limited` is `retry_after_s:int -> t`, without
  the `()` it took after its one argument, which is labelled and not
  optional: `Refusal.rate_limited ~retry_after_s:30`.

- `spindle_postgres` asks for rowtype 0.3.0 and postgres-eio 0.2.0, and
  pins both at those tags, so what changed there reaches a program through
  it. Breaking: a statement on a closed connection is
  `` `Connection `Closed `` in `Spindle_postgres.error`, where it was
  `` `Closed ``; a fiber cancelled while `Pool.use`, `query` or
  `transaction` runs its work stops at once, its connection closed and made
  again at the next lend, where the work ran to its end; and a program
  that uses rowtype itself moves to 0.3.0 with it.

- In `spindle_postgres`, `Session`'s store tells a busy pool in the pool's
  own words, "no connection came free within the pool's wait", as
  `error_to_string` and the libraries under it do, where it said "no
  connection within the wait".

- A connection's last bytes -- what a WebSocket handler wrote before it
  returned, a stream's last chunk -- have `send_timeout` from the last
  byte the client took, as every answer has, and the connection is closed
  once it passes. A client that stopped reading held its connection slot
  for ever.

- `Spindle_client.websocket` returns once a send to a server that stopped
  reading answers `Lost`: what was left unwritten has `timeout` for the
  server to take anything, and is then dropped with the connection. The
  call waited for it to go, which could be for ever.

- `Spindle_client.stream` takes an answer whose head arrived in the instant
  its deadline passed, where it answered `Timeout` and left the answer's
  connection open until the client's switch ended.

- `Response.stream ~length` below zero is the route's bug, answered `500`
  with an error in the log, as a header that frames the answer is. The
  server wrote `Content-Length: -1` and raised `Invalid_argument` into the
  producer at its first send.

- In `spindle_postgres`, `Pool.check` fails once the pool is closed, or
  closing, where `/readyz` answered `200`: a closed pool has no connection
  idle, which the check read as every connection lent.

- In `spindle_postgres`, `Session.schema` for a table whose name is longer
  than 52 bytes leaves its index for Postgres to name, where it named it
  after the table and Postgres cut that name to 63 bytes: at 63, the
  table's own name, and the schema failed with `42P07`.

- `Spindle.Server.run ~host` reads `localhost` in any case, `LocalHost`
  included, as both loopback addresses; another case went to the
  resolver, which may name only one.

- `Spindle_client` reads a server's `Keep-Alive: timeout="5"`, quoted, as
  it does `timeout=5`, where it read no timeout and kept the connection
  idle for its own `idle_timeout` beside a server that closes it sooner.

- `Spindle.Test.app`'s refusal of a `Files.directory` route tells a test to
  serve a directory it opened with `Files.route`, where it named
  `Static.load` and `Static.route` for either; its documents name both
  routes it refuses.

- A WebSocket handler that raises ends its socket's line at `error`, with
  what was raised and where (`error.kind`, `error.message`, `error.stack`),
  as a stream's or a background job's raise is; it was an `info` line that
  said only that the handler raised.

- The examples atop `Spindle` and `Spindle.Returns` type-check: the first
  serves `routes ~engine`, the second answers `find_user id`.
  `spindle.http`'s README says what its readers answer as they do.

- `Spindle_client.error`'s deadline that passed is `Timeout`, where it was
  `Timed_out`: the word postgres-eio and Eio's own `Timeout.run` give the
  same failure. Breaking: a match on a call's error names `Timeout`.

- A body's failures have one word each, in `Spindle.Body.error` and in
  `Spindle_http.Framing.read` and `read_some` alike: a body that could not
  be read is `Unreadable` in both, where `Framing` answered
  `` `Broken ``, and one the server's `body_budget` had no room for is
  `Over_budget`, where both answered `Busy`, which said nothing of the
  budget. The answer is unchanged: `503 busy`. Breaking: a match on a
  body's error names the new constructors.

- In `spindle_postgres`, a pool's failures are its states under `` `Pool ``:
  `` `Pool `Busy `` where `Spindle_postgres.error`, `Pool.use`, `query` and
  `transaction` answered `` `Busy ``, and `` `Pool `Closed `` for a pool
  closed, or closing under a borrow waiting, at once, where a closed pool
  waited out `wait` and answered `` `Busy ``. `refusal` answers both
  `503 busy`, logged as a warning with no detail, and `error_to_string`
  words the closed one "the pool is closed". A closed connection stays
  rowtype's, a `500`. Breaking: a match on what a pool answers names
  `` `Pool ``.

- `Spindle.client_gone`, a dependency, is a promise the server resolves
  once a request's client has gone: an events stream's write failing, its
  keep-alive's included, or the exchange ending. `Broadcast.next ~until`
  answers `None` once it resolves, so a producer waiting on a quiet topic
  ends when its client leaves, and gives back its fiber and connection
  slot, rather than at the next event. Nothing is cancelled; a producer
  that does not wait on it learns at its next `send`, as before.

- In `spindle_cli`, every command's `--help` lists exit status 1, what `api
  check` exits with on a stale file, and no longer lists 123, which no
  command exits with.

- In `spindle_postgres`, `Session` quotes its table's name in every statement
  and in its schema, so a name SQL reserves, such as `user` or `order`, is
  a table like any other. Each statement failed as a syntax error.

- Breaking: `Rate.limit` counts a key that is an IPv6 address by its /64,
  and one mapped from IPv4 as that IPv4 address. Each address was its own
  key, so a client changing its address within its /64 grew the table and
  was never limited.

- Breaking: `Compress.make` raises `Invalid_argument` for a `~level`
  outside 1 to 9 or a negative `~min_bytes`, and `Rate.create` for a
  `~limit` or `~burst` below one or a `~per` of zero. A level was clamped into range, a negative size
  compressed everything, and a limit of nothing was read as one.

- Breaking: a plain `OPTIONS` of a path a route names, where no route
  declares `OPTIONS`, is `204` with `Allow` listing the path's methods,
  `OPTIONS` among them (RFC 9110 §9.3.7), and `OPTIONS *` is `204`. Each
  was `405`, or `404`, and a `405`'s `Allow` now names `OPTIONS` too. A
  CORS preflight is answered as before.

- Breaking: `Response.make` at `204` or `304` names no content type unless
  given one, since neither has content (RFC 9110 §15.3.5, §15.4.5). Each was
  sent `text/plain; charset=utf-8`, the default for a body, with none.

- Breaking: a request whose target is a path or `*` and whose `Host` is
  empty is refused `400`, as RFC 9110 §4.2.1 has an http URI with no host.
  It was read as naming no host. An absolute-form target's authority still
  stands for an empty `Host`.

- Breaking: `Files` answers a file a browser would open as a page of the
  application's origin -- HTML, SVG, any XML -- as an attachment, with
  `Content-Security-Policy: sandbox`. It answered one inline, so an
  uploaded `.html` or `.svg` ran its script as the site; `nosniff` keeps a
  browser from guessing a type, not from running the one it is given.
  `~inline_active:true` shows one inline, still sandboxed.

- In `spindle_postgres`, `error_to_string` tells any `Spindle_postgres.error`
  in words for a log, as rowtype tells it, with no value in them.
- Breaking: OCaml 5.5 or later is required. The opam files asked for 5.4,
  which CI tested and nothing else did; every switch the code is written
  in is 5.5.
- Breaking: `spindle_postgres` logs on the source `spindle_postgres`, its
  library's name, where it was `spindle.postgres`, which read as a part of
  `spindle`. A level set for the old name no longer reaches it.
- The `spindle_postgres` package names postgres-eio among its dependencies,
  which it pins, so installing it from source no longer warns.
- In `spindle.client`, a `Body.read` after one that failed answers that
  failure again. Over HTTPS it raised `Eio.Cancel.Cancelled` into a caller
  nobody had cancelled, after a read that timed out. Breaking: over HTTP
  such a read waited again.
- In `spindle_postgres`, a `Pool.run` whose fiber is cancelled passes the
  cancellation on. It raised `Fun.Finally_raised` instead, which a
  `Fiber.first` it lost re-raised.
- `Server.run`: on Linux, `localhost` whose port another process holds on
  `[::1]` fails as in use. It served `127.0.0.1` alone, beside the other
  process, which a browser asking for `[::1]` first reached instead.
- `Trace`: a span whose fiber is cancelled ends with its status unset. It
  ended as `Error "Cancelled"`, counting a race lost or a client gone as a
  failure.
- `Websocket`: TLS failing beneath an open socket ends it as `Lost`, as a
  connection that ends does. A `wss` client raised the TLS exception from
  `Spindle_client.websocket`.
- `Websocket`: a send cancelled partway through its frame ends the socket
  as `Lost`, and every later send answers that. Each answered `Ok`, and
  what it wrote, a close included, went into the cut-off frame's payload.

- Breaking: a query is read as a form is, by
  `Spindle_http.Urlencoded.parse`: `?q=a,b` is the one value `a,b`, and
  `?t=a,b&t=c` the two values `a,b` and `c`. A value was split at each
  comma, so `Query.optional` read `a` and `Query.list` three values. A
  name with no `=` (`?q`) is given the empty value, as in a form; it read
  as absent.

- Breaking: a path segment, a query parameter, a header or a cookie whose
  text is not UTF-8 is refused at its place (`path.<name>`,
  `query.<name>`, ...), as a form's field already was. A codec was handed
  the bytes, and a JSON route that answered with them a `500`, unable to
  write them.

- A chunked body's extensions are held to RFC 9112 §7.1.1, a server's
  and a client's alike: a control byte or an unclosed quote in one breaks
  the body. Anything after the size's `;` passed unread.

- Breaking: a header input sent on several lines is read as one field. A
  list codec (`Codec.accept`, `weighted`, `cache_control`, `forwarded`,
  `structured_list`, `structured_dictionary`) reads every line, joined by
  `, `, as RFC 9110 §5.3 has it; any other codec refuses the input as
  `malformed` at `header.<name>`, since a field that holds one value sent
  twice is an invalid message. Every codec read the first line alone.

- A request refused for its framing or its fields is logged by what is
  wrong, without the bytes: a Content-Length, a chunk size, a field name, a
  method or a version that is not one is no longer quoted in the head's
  refusal line or the body's `unreadable` warning, where a token sent in
  its place was written out.

- Breaking: `Cookie.signed` and `Cookie.encrypted` take the age the server
  holds a cookie to as `~max_age_s`, in seconds, and it is required. It was
  `?max_age`, and a cookie declared without one was accepted for ever,
  however long ago it was made or copied.

- Breaking: `Static` skips a name that begins with a dot as it reads a
  directory, at any depth, unless given `~dotfiles:true`, as `Files`
  refuses one: an `.env` or a `.git` a build left beside a site was served.
  `.well-known` is read either way (RFC 8615). `Static` and `Files` answer
  every file with `X-Content-Type-Options: nosniff`, so a browser never
  runs one whose bytes look like HTML as a page of the site.

- `Codec.custom` takes `?list:true` for a list field of the application's
  own, so a header it reads sent on several lines is read as one, its
  lines joined by `, `, as the framework's list codecs read one. Without
  it such a header is refused as `malformed`.
- Breaking: `Static` reads `.well-known` at the site's root alone, where
  RFC 8615 places it; one deeper is a dot-name like any other, skipped
  unless `~dotfiles:true`.

- Breaking: `Cookie.make`'s `?max_age` is `?max_age_s`;
  `Refusal.rate_limited`'s `~retry_after` and `Refusal.busy`'s
  `?retry_after` are `~retry_after_s` and `?retry_after_s`; `Event.retry`
  and `Spindle_http.Event_stream.retry` take `~ms`, and an event read from
  a stream, `Spindle_http.Event_stream.event`, holds its reconnection time
  as `retry_ms`, where it was `retry`; and `Response.stream`'s
  `keep_alive` is a record, `{ quiet; filler }`, where it was a pair.

- Breaking: the OpenAPI document is valid for every route. Two
  dependencies that read one input -- a query parameter, a header, whose
  name is matched without case, a cookie, a form's field -- are one
  parameter, required where either is; it was listed once per dependency,
  which OpenAPI forbids. Two that read it as different things, two codecs
  or one value and a list, are refused by `App.make`. A JSON request
  body says `"required": true` unless every member of its description
  may be left out, since an empty one is read as `{}`; a raw one, read
  empty or not, says nothing.
- Breaking: a framework code a route answers is declared only where its
  document lists it, from what the route reads, so a handler answering
  `Refusal.not_found` declares it in `~refuses` as its own. Any route
  could answer any of `Refusal.Code.framework` undeclared, and the
  document promised none of those it did not list; such a refusal is now
  logged as undeclared, and `Test.call` raises on it. `Static` and `Files`
  declare their `404`.

- `Server.run` checks its limits before it binds and calls `ready`, as
  its `.mli` said: a limit out of range raised only after the port was
  held and `ready` had announced it.
- Breaking: a graceful stop waits for a stream of known length, a file
  above all, to send its last byte, within `drain`, as it does for any
  answer being made. It counted such a stream as finished once its head
  was sent, and cancelled it mid-file if nothing else was in flight.

- Breaking: `Spindle_cli.run` takes the program's `env` in place of its
  final `()`, and runs in the program's event loop: it called
  `Eio_main.run` itself, which a library leaves to its program, and
  `spindle_cli` no longer links `eio_main`. Write
  `Eio_main.run @@ fun env -> Spindle_cli.run ~name ~app env`.

- Breaking: `Spindle_http.Field.line` and `Field.unfold` are gone. Each
  was one step of one reader -- a chunked body's line, a response's
  folded field -- and is now inside it.

- In `spindle_postgres`, an exhausted pool's `503 busy`, from
  `Spindle_postgres.refusal`, is logged as a warning on
  `spindle_postgres`. It was the refusal's detail, which every `5xx` logs
  as an error, so a server under load paged as though broken.

- In `spindle_cli`, `api check` checks both files and names each that is
  stale or missing. It stopped at the first, so a run that named the
  OpenAPI document left a stale Zod module for the next.

- Breaking: the origin check reads `Sec-Fetch-Site` as the Structured
  Field item it is, a token: `same-origin;x=1` is `same-origin`, and
  `Same-Origin`, a quoted `"same-origin"` or the field sent on two lines
  is another site. It was compared as text without case.

## 0.2.0 (2026-10-08)

- Breaking: Spindle needs wiretype 0.2.0, whose changes reach an
  application through it: a refusal's `at` quotes a member name that is not
  plain (`body["a.b"]`), an answer holding a float that is not finite is a
  `500` rather than `null`, and the document's schemas say what the reader
  means where they once guessed. wiretype's CHANGES.md lists each.
- Spindle needs eio 1.6, the first to raise `Eio.Fs.Symlink`, which
  `Files` has matched since 0.1.0, whose opam files allowed 1.5.
- `spindle`: `Codec.float` reads a number in decimal digits, with an
  optional minus sign, fraction and exponent, and refuses what
  `float_of_string` would also take but no client means, and a number too
  large for a float. It is described as `number`. Breaking: `Number` joins
  `Codec.shape`, so a match over it needs the case.
- `spindle`: `Codec.uuid`, `Codec.date` and `Codec.instant` read a UUID,
  an RFC 3339 date and an instant as wiretype's kinds read them in a body,
  and are described with their formats. Breaking: `Format` joins
  `Codec.shape`.
- `spindle`: `Query.default` and `Header.default` read an input that may be
  absent as its value or a default, and the document says the default.
  Breaking: `default` joins `Dep.input`.

## 0.1.0 (2026-10-07)

First release.

- `spindle`: routes as values, a method and a path declared together;
  dependencies that list what a route reads and run once per request;
  typed answers and refusals from declared codes; signed and encrypted
  cookies and sessions; rate limits, CORS, an origin check, compression,
  static files read at startup and files beneath a directory; event
  streams, broadcasts and WebSockets; logging with a request's id on every
  line, metrics and traces; and the routes described as OpenAPI 3.2 and
  zod, served with Scalar's reference.
- `spindle.http`: HTTP/1.1 read and written by itself -- heads, framing,
  fields, dates, structured fields, multipart -- each requirement of RFC
  9112, RFC 9110 and RFC 6455 it meets a row of its suites.
- `spindle.client`: calling another server over HTTPS with the system's
  trust store, a kept connection per domain and a deadline per call, and a
  WebSocket client, linking no framework.
- `spindle_postgres`: a server's Postgres over rowtype's backend:
  connections bounded as a server bounds them, a pool and its probe, and a
  failure's refusal.
- `spindle_cli`: an application's command line, writing and checking its
  OpenAPI document and zod from the routes.
