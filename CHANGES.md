# Changes

## Unreleased

- Breaking: OCaml 5.5 or later is required. The opam files asked for 5.4,
  which CI tested and nothing else did; every switch the code is written
  in is 5.5.
- Breaking: `spindle_postgres` logs on the source `spindle_postgres`, its
  library's name, where it was `spindle.postgres`, which read as a part of
  `spindle`. A level set for the old name no longer reaches it.
- `spindle_postgres` names postgres-eio among its dependencies, which it
  pins, so installing it from source no longer warns.
- `spindle.client`: a `Body.read` after one that failed answers that
  failure again. Over HTTPS it raised `Eio.Cancel.Cancelled` into a caller
  nobody had cancelled, after a read that timed out. Breaking: over HTTP
  such a read waited again.
- `spindle_postgres`: a `Pool.run` whose fiber is cancelled passes the
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

- Breaking: every duration names its unit, and its type is what the value
  is: a wait counted on a clock a float of seconds, a value a protocol
  writes in whole seconds an int. `spindle_postgres`'s
  `?connect_timeout_s`, in `connect`, `Pool.create` and `Pool.run`, takes
  a float, as `?timeout_s` and `?wait_s` beside it do and as postgres-eio
  holds it; `Cookie.make`'s `?max_age` is `?max_age_s`;
  `Refusal.rate_limited`'s `~retry_after` and `Refusal.busy`'s
  `?retry_after` are `~retry_after_s` and `?retry_after_s`;
  `Event.retry` and `Spindle_http.Event_stream.retry` take `~ms`; and
  `Response.stream`'s `keep_alive` is a record, `{ quiet_s; filler }`,
  where it was a pair.

- Breaking: the OpenAPI document is valid for every route. Two
  dependencies that read one input -- a query parameter, a header, whose
  name is matched without case, a cookie, a form's field -- are one
  parameter, required where either is; it was listed once per dependency,
  which OpenAPI forbids. Two that read it as different things, two codecs
  or one value and a list, are refused by `App.make`. A JSON or raw
  request body says `"required": true`.
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
  above all, to send its last byte, within `drain_s`, as it does for any
  answer being made. It counted such a stream as finished once its head
  was sent, and cancelled it mid-file if nothing else was in flight.

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
