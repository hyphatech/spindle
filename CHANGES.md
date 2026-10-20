# Changes

## 0.9.0 (2026-10-20)

- Breaking: `Spindle.Dep.of_body` takes `?content_types`, as
  `Spindle.body_stream` does, where it took `~need:Dep.body`:
  `Dep.of_body ~content_types:[ "text/csv" ] parse`. It always read the
  body whole and handed over the string, so a `need` of `Multipart`, `Stream`,
  `Form` or `Json` only made the API's document say what it never did. A JSON
  body is `Spindle.json`'s; `Dep.needs` reports a body as before.

- Breaking: `Spindle.Cache.forever ~under` takes paths, as every `?at` does:
  `~under:Spindle.Path.[ s "assets" ]`, where it took `[ "/assets/" ]` and
  raised for a string that did not begin and end with `/`. A path is under
  one when it is beneath it, so `/assetsheet` never is under `/assets`.

- Breaking: a CORS policy is made by the kind of origin it allows:
  `Spindle.Cors.origins ~credentials:true [ "https://app.example.com" ]` for
  sites named, and `Spindle.Cors.any ()` for any site, which takes no
  `~credentials`, so a policy letting every site act as the signed-in person
  -- which the Fetch standard refuses -- is a compile error where
  `Cors.make ~credentials:true Any` raised as the server started.
  `Cors.make` and the `origins` type are gone.

- Breaking: `Spindle.Openapi.routes` is the routes that serve the API's
  document and reference, a plain list, as `Health.routes` and
  `Metrics.routes` are, raising for routes written wrong in source: it was
  `Openapi.docs`. The one that answers a `result`, for routes built at run
  time, is `Openapi.make`, as `App.make` is: it was `Openapi.routes`, so a
  name meant one thing in one module and another in the next.

- Breaking: `App.make`, `Spindle.serve` and `Test.app` take `~refuses`, where
  they took `~codes`: the codes the middleware may refuse with, named as a
  route's and a dependency's are, so one word declares them everywhere.
  `Dep.codes` and a route's `codes` still read them back.

- Breaking: `spindle.http` promises what an application names, and keeps
  how Spindle reads and writes the wire apart, under
  `Spindle_http.Private`, as Eio keeps its own under `Eio.Private`:
  `Head`, `Framing`, `Write` and the WebSocket runner -- `run_server`,
  `run_client` and `accept_key` -- are there, not covered by the library's
  version, so how a body is framed or a head written can change in any
  release. A request's version is `Spindle_http.Version.t`, where it was
  `Spindle_http.Head.version` (`~version:Spindle_http.Version.Http_1_0` in a
  test), and an HTTP-date is written with `Spindle_http.Date.to_string`,
  where it was `Write.date`. `Connection` stays, since
  `Spindle.Response.takeover` hands it to an application.

- Breaking: a socket's failures are open tags, as a call's and a
  statement's are, so a handler's `let*` runs over `Ws.receive`, `Ws.send`
  and its own work alike: `` `Socket (`Closed c) `` -- the socket's own state,
  under its name, as `` `Pool `Busy `` is a pool's -- `` `Lost ``,
  `` `Undecodable `` (was `Unreadable`, a message its description could not
  read) and `` `Unwritable ``. A handler, the server's and the client's, may
  end with a failure of its own beside the socket's, which closes it `1011`
  and is logged; it had to disguise one as a socket's. `Spindle_client`'s
  `websocket_error` holds the socket's tags where it wrapped them in
  `` `Websocket ``, so its `` `Lost `` and the socket's are one.
  `Websocket.close` is the record a close carries.

- Breaking: what a handler reads a body with answers what a handler answers.
  `Spindle.Body.read`, `Spindle.Multipart.next` and `Spindle.Multipart.read`
  fail with a `Refusal.t` -- a body too large `413`, one the server has no
  room for `503 busy`, one that stops arriving `400`, a form that is no
  multipart `400 invalid` -- as `Spindle.Session`'s calls already do, so a
  handler goes on through them with `let*` and converts nothing; the code
  still tells one from another. `Body.refusal`, `Multipart.error`,
  `Multipart.error_to_string` and `Multipart.refusal` are gone. `Body.error`
  stays, as what a connection loop's `Body.source` says.

- Breaking: what a server lets a client make it hold or wait for is one
  value, `Spindle.Server.Limits.t`, given as `~limits` to `Spindle.serve`,
  `Server.run` and `Server.serve_on`, where each took thirteen arguments:
  `max_body`, `max_header_bytes`, `head_timeout`, `idle_timeout`,
  `body_timeout`, `min_body_rate`, `send_timeout`, `discard_limit`, `linger`,
  `body_budget`, `max_connections`, `backlog` and `drain`. Their defaults are
  written once, in `Limits.make`, which refuses one out of its range where it
  is made: `~limits:(Spindle.Server.Limits.make ~max_body:(10 * 1024 * 1024)
  ())`. `serve` takes about twenty arguments, the ones a program sets.

- `Spindle.serve` and `Spindle_client.run` take the capabilities they use,
  as `Spindle_postgres.Pool.run` does, where they took the whole
  `Eio_unix.Stdenv.base`: `serve` the network, both clocks, the domain
  manager and the filesystem, and the client the network and the monotonic
  clock. `env` is still what a program passes; a test may pass an object
  with only those, a mock clock among them.

- Breaking: a plain cookie that does not read is absent, as a signed or
  encrypted one that fails its check already was: `Cookie.optional` answers
  `None`, and `Cookie.required` refuses it as missing, with a `debug` line
  naming the cookie. It was `400 invalid`, so a value an older deploy wrote
  -- an enum's word since removed -- refused every page that read it, and
  the person could not mend it from the site. FastAPI refuses such a value;
  the server wrote the cookie and the browser only kept it, so Spindle
  holds it to the rule its sealed cookies keep.

- Breaking: counting never raises. `Spindle.Metrics.inc` with a negative
  `~by`, and `inc`, `add` or `observe` with a number of label values other
  than the family's, raised `Invalid_argument` inside the request that
  counted, so a route that had done its work answered `500` for a metric.
  Such a count is left out, and logged once for its family, as a sampled
  gauge's series of the wrong length already was.

- Breaking: a plain cookie holds any text. What RFC 6265 leaves out of a
  value -- a space, a quote, a comma, a semicolon, a backslash, a control
  character -- is percent-encoded, and so is `%`, and reading decodes any
  escape, as Express and Rails do: `Cookie.make theme "Kim Li"` is written
  `theme=Kim%20Li` and read back as `"Kim Li"`. `Cookie.make` raised
  `Invalid_argument` on such a value, so a cookie set from what a request
  brought answered `500`. A word, a tag or a token keeps its spelling; a
  value written raw with a `%` reads differently.
  `Spindle.Cookie.encoded`, the codec that held such text, is gone: every
  plain cookie holds it now.

- Breaking: what a handler sets -- a cookie with `Spindle.set_cookie`, a
  header with `Spindle.add_header` -- goes with its answer, an `Ok` or a
  refusal, as a 4xx a handler renders carries its cookies in Rails and Plug.
  It went with an `Ok` alone, so a session moved before a refusal --
  `Session.rotate`, then a wrong password -- had changed its store but not
  the browser's cookie, and signed its person out. A field the refusal writes
  itself -- a challenge, a `Retry-After` -- is the one sent, never beside the
  handler's of the same name.

- An app given its keys as a resource -- `Spindle.Dep.resource Spindle.keys
  ring` among `~resources` -- seals its cookies under them. It started, and
  read its signed and encrypted cookies, but answered `500` wherever a route
  set one, since only `~keys` was what cookies were sealed under.

- `Spindle_client.call`, `stream`, `events` and `Body.read` answer
  `[> Spindle_client.error ]`, and `websocket` `[> websocket_error ]`, open as
  rowtype's and `Spindle_postgres`'s failures are, so a handler's one `let*`
  runs over a call and its own failures, as `Spindle_client.error` says; they
  were closed, and such a `let*` did not compile.

- `Spindle.Health.routes`, `Spindle.Openapi.routes` and `Spindle.Openapi.make`
  take `?guard`, as `Spindle.Metrics.routes` does: a `unit Dep.t` run first,
  whose refusal is the answer, so the probes and the API's reference can be
  kept from whoever must not read them, where only the metrics could.

- Breaking: the not-found answer is written as a route's handler is, with
  no method or path, as Axum's fallback is a handler like any other.
  `~not_found` -- on `Spindle.serve`, `App.make` and `Test.app` -- is a
  `(Response.t, Refusal.t) result Dep.t`, where it was a function of the
  request, so a page for a path nobody serves reads a session, a cookie or a
  resource as every other page does; one that reads nothing is
  `Spindle.Dep.return (Ok page)`. A resource it reads is checked where the
  app starts, naming it, and the codes its inputs declare are ones it may
  refuse with.

- Breaking: an app is made, then started, and each start is an instance
  of its own. `App.start` answers an `App.instance` -- what
  `App.handle`, `Server.run`, `Server.serve_on` and `Test.call` take --
  where it wrote what it was given into the app, so one app started twice,
  for a server and for a test, or from two directories, had the second's
  resources and files in both. `App.make` takes what is written in source;
  `App.start` takes what exists once the program runs: `~resources`,
  `~keys`, which moved from `App.make`, `~mono_clock`, and `~fs`, now
  optional, needed only where a route reads a directory as it starts.
  `Test.app` answers an instance, and what describes an app --
  `Openapi.document`, `Zod.schemas`, `Melange.client`, `App.routes` --
  takes `App.t`, or `App.app instance`. An app that was never started can
  no longer be called, so the `500` it answered is gone.

- Breaking: `Spindle_client` has one response, `'body response`, its
  body's type saying how it arrived: `call` answers a `string response`,
  the whole body, and `stream` hands its function a `Body.t response`,
  read as it arrives, as Java's `HttpResponse<T>` is one type for both.
  `answer` is gone, so what reads a status or a header reads either. A
  type written as `Spindle_client.response` is `string
  Spindle_client.response`.

- Breaking: `Spindle.client` is `Spindle.client_ip`, and `Request.client`
  and `Request.make ?client` are `client_ip`: the caller's address, as
  `req.ip` and `remote_ip` name it, where "client" also named the HTTP
  client, a WebSocket's client messages and the connection
  `client_gone` waits on. `Path.str` is `Path.string`, beside `Path.int`
  and `Codec.string`.

- Breaking: what serves a folder no longer says how long a browser keeps
  it. `Static.load` and `Static.directory` take no `~immutable`, and serve
  every file `no-cache` with its entity tag, as `Files` does, so
  `Static.directory "dist"` is the whole of serving one. Keeping the
  hashed assets a build names a year is the application's policy:
  `Spindle.Cache.forever ~under:Spindle.Path.[ s "assets" ]`, a middleware,
  keeps every successful `GET` or `HEAD` under those paths a year, whichever route
  answered it, and never a failure. `Response.with_header` sets a header
  in place of one already there, which a middleware deciding one for
  every route needs.

- `Spindle.Syntax` holds `let*`, `Result.bind`, beside `let+` and `and+`,
  so a handler goes on through its `result` with the one `open` it already
  writes, where each program defined its own: `Result.Syntax`, from OCaml
  5.4, has a `let+` of its own that would hide the inputs'.
- Breaking: a session's `get`, `put`, `rotate` and `destroy` answer a
  `Refusal.t` -- a `500`, the store's words in the log -- since a handler
  can do nothing else with a store that fails, so each goes on with `let*`
  beside the handler's own. `Session.error`, `error_to_string` and
  `refusal` are gone.
- Breaking: the keys signed and encrypted cookies are sealed under are the
  server's, given where it starts -- `Spindle.serve ~keys`, `App.start ~keys`,
  `Test.app ~keys` -- as Rails and Phoenix take their secret, so a cookie,
  and the routes that read it, are values made before the secret is read.
  `Cookie.signed` and `Cookie.encrypted` take no ring:
  `Cookie.signed ~max_age "who" codec`. A route that reads such a cookie in
  an app given no keys stops the server before it listens, naming the
  route; one that only sets one is answered `500`, logged.
  `Cookie.Named.unseal` takes `~keys`, and `Spindle.keys` is the ring as a
  dependency, for a handler that signs or seals with `Key.sign` or
  `Key.seal`.

- Breaking: a health check reads what it asks about as a route does, so
  the probes are routes made with the rest, before the pool or anything
  else the application holds exists, and a command line describes them
  with none. `Spindle.Health.check name f` takes `f` as a dependency of
  the function a probe runs: `Spindle.Dep.return (fun () -> ...)` for a
  check that reads nothing, `let+ cache = cache in fun () -> ...` for one
  that reads a resource. `Spindle_postgres.Pool.check` takes the pool's
  resource, `Pool.check db`, where it took the pool, and the server is
  handed the pool with `~resources` as for every other route. `/livez`
  reads nothing.
- Breaking: a session is a dependency, the request's session as other
  frameworks have it. `Spindle.Session.create` answers it,
  and a route reads it with `let+ session = session`, handed the session
  its request's cookie names; `Session.get session` reads its data,
  `Session.put session data` writes it, starting a session where there
  was none, `Session.rotate session` moves it to a new id at sign-in, and
  `Session.destroy session` ends it. Each sets the cookie and reads the
  clock itself, so a route passes neither. Every use in one request is the
  same session, and the store is asked once. `find`, `start`, `renew`,
  `update`, `close`, `cookie`, `data` and the `id` and `session` types are
  gone.
- Breaking: `Session.create ~store` takes a `Session.store Dep.t`, so the
  store is read as a route reads anything the application holds:
  `Spindle.Dep.return (Spindle.Session.memory ())`, or
  `Spindle_postgres.Session.store db ~table` for the database, which
  checks the table's name and writes its statements once, where the store
  is made, and a session and the routes that read it are values made
  before the pool.
- Breaking: ended sessions are swept by the sessions themselves, and
  `Session.sweep` is gone. The first request to read a session ten minutes
  after the last sweep, on the app's monotonic clock, deletes up to 500 of
  the ended, the soonest first, and the next request another batch while a
  sweep finds a full one, so no request waits on more than a batch; a
  failed sweep is a warning in the log. A store's `sweep` takes `~limit`.
  The memory store keeps its sessions ordered by when they end, so a sweep
  costs what it deletes, where it walked the table under its lock, and the
  Postgres store skips rows another server's sweep holds.

## 0.8.0 (2026-10-19)

- `Spindle.Melange.client` prints the routes as one OCaml module for
  Melange, from the same walk as the OpenAPI document and the Zod schemas:
  wiretype's types for every shape, and a function per route that calls it,
  its inputs labelled and typed and its answer a promise of a `result` --
  the route's answer, or `` `Invalid `` an input that breaks its
  description with nothing sent, `` `Lost ``, `` `Refused `` with the
  server's refusal, or `` `Unexpected ``. A stream of events is a function
  handed each event as a variant, read over `fetch` and stopped with
  `Route.Stream.close`; a WebSocket's is handed each message typed, and its
  `Route.Socket.send` is typed, checked and held until the socket opens. A
  socket reading a header, and a response of any kind, have no function.
  `api melange` writes
  it, and `api check --melange FILE` holds a committed copy to the routes.
  Melange is a test dependency alone: a native user installs nothing new.
- Breaking: wiretype 0.6 is required.

## 0.7.0 (2026-10-16)

- Breaking: `Spindle.Zod.module_` is `Spindle.Zod.schemas`, a noun like
  `Openapi.document`, without the trailing underscore.
- A resource is what the application holds -- a pool, a client, a hub --
  read by a route as a dependency: `Dep.of_resource "database"` names one,
  `let+ pool = db in` reads it, and `Spindle.serve`, `App.start` and
  `Test.app` take `~resources:[ Dep.resource db pool ]`. The routes are
  then a value, made before any database is, so a command line or a
  document describes them with none. A route reading a resource the server
  was not given stops it before it listens, naming the route and the
  resource, as does one supplied twice or a `Dep.resource` of what
  `of_resource` did not make; one read inside `Dep.bind` and not supplied
  answers `500`, logged by name. `Test.app` needs only the resources the
  routes a test calls read, and `Test.call` raises `Invalid_argument` on
  one that reads a resource it was not given. The API's document and the
  Zod schemas never list a resource, which no request carries.
  `Dep.need` has a `Resource` constructor.
- Breaking: `Spindle_cli.run`'s `~app` is the app itself, a
  `(Spindle.App.t, string) result`, where it was a function of the
  environment and a switch, and the `Spindle_cli.app` type is gone. It
  takes `()` where it took `env`, so a command line needs no event loop:
  `let () = Spindle_cli.run ~name ~app:(Spindle.App.make routes) ()`.
  Routes that read their database as a resource need nothing made to be
  described.
- Breaking: `Rate.create` takes no `~mono_clock`, so a limit is a value
  made at the top level, beside the routes that read it:
  `let sign_ins = Spindle.Rate.create ~limit:10 ~per:Mtime.Span.min ()`.
  Its counts are the app's, so two apps -- two servers, two tests -- never
  share a key's, and they are timed on the monotonic clock `App.start` now
  takes as `~mono_clock`, which `Spindle.serve` gives from its
  environment; a limit in an app never started answers `500`. A test
  gives `Test.app ~mono_clock` an `Eio_mock` clock to move; by default its
  clock never moves.

## 0.6.1 (2026-10-16)

- Installs from Hypha's opam repository:
  `opam repo add hypha https://github.com/hyphatech/opam-repository.git`,
  then `opam install spindle spindle-postgres spindle-cli`. The
  `pin-depends` are gone: spindle takes wiretype 0.5 and rowtype 0.8, each
  up to its next breaking release.

## 0.6.0 (2026-10-15)

- An answer is written by the fiber that flushes it, where every flush was
  handed to a writer fiber of the connection's own and waited for: a send
  is one write, with no fiber woken and no promise to wait on, and a
  deadline moves by writing an `int`, where it boxed an `Mtime.t` each
  time. Sending to many clients at once leaves far less for the collector
  to promote -- delivering an event to ten thousand subscribers costs about
  a third less CPU -- and a plaintext answer about an eighth less. A write
  the socket refuses ends its connection without another attempt. A
  takeover is still handed a `Buf_write.t` with a fiber that copies it.
- `spindle-postgres` is pinned to rowtype 0.8.0, its latest release,
  where it was pinned to 0.7.0.

## 0.5.0 (2026-10-14)

- A content type a route takes that is no `type/subtype`, `type/*` or
  `type/*+suffix` -- `"json"`, `"application/ json"`, one with parameters
  -- is refused by `App.make`, naming the route and the pattern, so
  `Spindle.serve` and `Test.app` raise on it, where it matched nothing and
  refused every body without a word. `Compress.make` raises
  `Invalid_argument` for such a `~types` entry, which compressed nothing.
  `Spindle_http.Media_type.is_pattern` is the test.
- Through wiretype 0.5.0, an answer outside its description's bounds is
  never written: the route's bug, a `500` logged with why. A read-only
  member a request sends is not read, and a write-only one is never in an
  answer, as the API's document already said.
- Breaking: `spindle` needs wiretype 0.5.0, and depends on Uuidm.
  `Spindle.Codec.uuid` is a `Uuidm.t`, where it was a `string`, as a UUID
  is in a body and in a row, so one identifier crosses them as one type.
- Breaking: a codec of your own is spelt as wiretype spells a kind:
  `Codec.custom ~kind ~parse ~print ()`, whose `~parse` answers
  `Ok` the value or `Error` the sentence a client is told, where it
  answered an option and `?expects` ended a sentence the framework made.
  `Codec.parse` answers the same `result`. `Codec.enum`'s `~kind` is
  optional, as `Wiretype.enum`'s is.
- Breaking: `spindle-postgres` needs rowtype 0.7.0 and postgres-eio 0.5.0.
  A connection target is a `Rowtype_postgres.Conninfo.t` for
  `Spindle_postgres.connect` and `Pool.create`, read from a connection
  string by `Conninfo.of_string`; `Pool.run`, a program's entry point,
  still takes the string and reads it once, a string that does not parse
  ending the program as a database that refuses does. `?connect_timeout`
  is gone: the target carries its own (`Conninfo.with_connect_timeout`),
  and one that names none is still bounded at 10 s.
- Breaking: `Spindle_postgres.Pool.query`, which runs one statement, is
  `Pool.exec`, so it is not taken for rowtype's `run` beside `Pool.run`,
  the program's pool. `Spindle_postgres.error` is
  `` [ Rowtype.error | Rowtype_postgres.Transaction.failure
  | Rowtype_postgres.Pool.error ] ``, and `error_to_string` is
  `Rowtype_postgres.error_to_string`, the one printer for all of it.
- rowtype's new `` `Unsent `` -- the database could not be reached, so
  nothing was done -- is answered by `Spindle_postgres.refusal` as
  `503 busy`, with `Retry-After: 1`, as `` `Pool `Busy `` is, and logged
  as a warning.
- `spindle-postgres` no longer sets `DateStyle`: the driver sets it, and
  the other settings it reads text by, on every connection itself.
- A closing connection's last bytes are read against the connection's
  deadline, for `linger`, as every other wait on a client is, where a timer
  of its own bounded them; a deadline's tick counts `linger` among the
  limits it is a tenth of, so it is a tenth of a second at the defaults.
- `Request.client` read from a trusted proxy's `X-Forwarded-For` is the
  address alone, where an element written `1.2.3.4:5678` or
  `[2001:db8::1]:4711` was taken whole: every connection was a client of
  its own, and a `Rate.limit` keyed by the client limited nobody. A trusted
  hop written with its port is passed over as one without.
- A log line is UTF-8 and one line whatever it holds: each byte of a
  message or a field that begins no character is written U+FFFD, as Go's
  `encoding/json` writes it, where a JSON line copied it and was one a
  shipper drops; and a `Pretty` line writes a line's end in its message or
  a field as `\n` or `\r`, where a Postgres error's `DETAIL` began a line
  of its own.
- Breaking: an exception's message is never logged. `Spindle_http.Log.raised`
  writes `error.kind` and `error.stack` and no longer `error.message`, and
  the `500` a raise is answered with, a stream's failure, a background
  job's and a connection's say the exception's kind, where each wrote
  `Printexc.to_string` -- whatever the raiser wrote, a card number among
  it. An I/O error's words, the operating system's, are still a failed
  connection's.
- Breaking: the packages `spindle_postgres` and `spindle_cli` are
  `spindle-postgres` and `spindle-cli`, and so are their libraries, as
  opam names a package; a `dune` file says `(libraries spindle-postgres)`.
  The modules stay `Spindle_postgres` and `Spindle_cli`. The log source
  `spindle_postgres` is `spindle-postgres`, the name a user installed.
- Every public `error` type has its printer beside it: `Session`,
  `Body`, `Multipart`, `Spindle_http.Head` and `Head.Response`, and
  `Spindle_http.Multipart` have `error_to_string`, and `Test` has
  `websocket_error_to_string`.
- Breaking: `Cors.make`'s `?headers`, the request headers a preflight
  allows, is `?allow_headers`, as `Access-Control-Allow-Headers` names
  them: `~headers:["x-token"]` read as headers to send, as everywhere
  else `?headers` is.
- Breaking: `now` is always an instant. `Spindle.serve`'s `?now`,
  `Server.run`'s and `Server.serve_on`'s `~now` and `Request.make`'s `~now`,
  each a `unit -> Ptime.t`, are `read_clock`, where `Test.call ~now` and
  `Session`'s `~now` stay a `Ptime.t`. `Spindle.clock_now clock ()` is
  `Spindle.of_clock clock`, which is `Spindle_http.Instant.of_clock`.
- Breaking: `Spindle.body_stream` takes `?content_types:string list`,
  each `type/subtype`, `type/*` or `type/*+suffix`, where it took a
  predicate on the raw `Content-Type`: the framework compares type and
  subtype without case and ignores parameters, so
  `application/octet-stream; charset=binary` is the type it names, and the
  OpenAPI document lists them as the request body's content, where it
  always said `application/octet-stream`. `Dep.of_body` loses
  `?content_type`: the types are its `need`'s, `Dep.Raw { content_types }`
  or `Dep.Json`'s, and `Dep.Raw` and `Dep.Stream` carry them.
  `Spindle_http.Media_type.matches` is the comparison, which
  `Compress.make`'s `types` use too.
- Breaking: `Spindle_client.error` is
  `` [ `Unsent of string | `Lost of string ] ``, the words every Hypha
  library uses for what happened to the work, so a handler's one `let*`
  runs over a client call and a database statement. `Unanswered` and
  `Timeout`, which a caller handled alike since the server may have acted
  on either, are both `` `Lost ``, a passed deadline's words saying so.
  `websocket_error` is `` [ error | `Not_upgraded of response | `Websocket
  of Spindle_http.Websocket.error ] ``, where it was `Failed`, `Refused`
  and `Ended`; and `events_end`'s `Refused` is `Answered`, so the two no
  longer share a constructor.
- A client call's deadline covers looking its host's name up: eio_posix
  looks a name up in a system thread no cancellation reaches, so a call
  with a 200 ms timeout waited for a slow resolver for as long as it took.
  One fiber of the client's, on its switch, now runs every lookup, and a
  call abandons its wait at its deadline.
- Under `compress`, every precondition sees through a compressed answer's
  marked tag: a route is asked `If-Match` and `If-None-Match` with the
  `-gzip` mark taken off -- `If-None-Match` where the request takes gzip --
  so `If-Match` holding the tag a client was given passes, where it was
  `412`, and an application's route compares the tags it set. A `304`
  repeats the marked tag where the client sent it, and every `304` says
  `Vary: Accept-Encoding` unless it names a type never compressed, as RFC
  9110 §15.4.5 requires of the `Vary` its `200` would carry; a `304` from
  `Static` or `Files` had none. `If-Range` still reads the tag as it came,
  since a part is only ever of the uncompressed answer.
- Breaking: `Spindle_http.Status.t` names every status RFC 9110 §15
  defines, and 103, 425, 428, 451 and 511 -- `` `Continue ``,
  `` `Early_hints ``, `` `Non_authoritative_information ``,
  `` `Reset_content ``, `` `Multiple_choices ``, `` `Use_proxy ``,
  `` `Payment_required ``, `` `Not_acceptable ``,
  `` `Proxy_authentication_required ``, `` `Length_required ``,
  `` `Expectation_failed ``, `` `Misdirected_request ``, `` `Too_early ``,
  `` `Precondition_required ``, `` `Unavailable_for_legal_reasons `` and
  `` `Network_authentication_required `` -- and `Spindle_http.Meth.t` names
  `` `CONNECT `` and `` `TRACE ``, where each was `` `Code n `` or
  `` `Other s ``. Both sets are closed at 1.0: a status or method
  registered later stays `` `Code n `` or `` `Other s `` for every 1.x
  release.
- Breaking: `Spindle_http.Websocket.send` of a text message that is not
  UTF-8 answers `Error (Unwritable _)`, a new constructor of `error`, and
  sends nothing, where it went on the wire for the peer to fail the
  connection with 1007 (RFC 6455 §8.1). A JSON value its description
  cannot encode answers the same, where it was logged and answered
  `Ok ()`. A handler that returns `Unwritable` closes its socket with 1011.
- Breaking: `Spindle_http.Multipart.to_string` answers a `result`, and
  refuses what its reader would not read back as itself: a boundary RFC
  2046 does not allow, a content type that cannot be written, and content
  holding the delimiter, which wrote a part of the caller's choosing into
  the body. A part's `headers` are not written, as the `.mli` now says.
- A takeover answered while the server stops is in flight from its route
  to its socket, so it gets the drain to say goodbye, where it was
  cancelled the moment its `101` had gone.
- A body read still waiting when its route's handler returns -- in a fiber
  the route left behind -- is stopped and answers `` `End ``, logged as the
  route's bug, before the connection loop reads on. The two read the
  connection at once, and the connection hung with no deadline.
- A `426` names its `Upgrade` in `Connection` (`upgrade`, or `upgrade,
  close` when the connection ends), as RFC 9110 §7.8 requires of every
  sender of `Upgrade`; a WebSocket route's `426` sent `Upgrade` alone.
- A client that asked for `100 Continue` and left before it was sent makes
  the route's body read answer `Error (Unreadable _)`, where
  `Eio.Buf_write.Flush_aborted` was raised into the route.
- A stream's `send` answers `Error Gone` once its producer has returned or
  raised, and logs it as the route's bug, where a fiber that kept `send`
  wrote its bytes between that answer and the next one on a kept
  connection.
- Breaking: a path parameter's `?or_not_found:()` is
  `?unparsed:Next_route`, which says what it does -- another route whose
  path matches is asked -- where the old name read as a `404`. Its
  default, `Path.Invalid`, is the `400` it was. `Route.param`'s
  `or_not_found` field is `unparsed`.
- Breaking: routes told apart by a parameter's type are one operation in
  `Spindle.Openapi`'s document and one entry in `Spindle.Zod`'s module,
  its parameter any of their types, reading and answering what either
  route does. With one name for the parameter the document was refused
  as two routes of one operation id; with two names it held one path
  twice, which OpenAPI refuses. Two routes whose paths differ only in a
  parameter's name -- `/items/{id}` and `/items/{item}`, under any
  methods -- are now the document's `Error`, saying to give them one
  name, and so are the routes of one operation that answer in different
  ways or read different bodies.
- A compressed answer revalidates: a `GET` whose `If-None-Match` holds
  the tag a gzipped answer carried, marked `-gzip`, is answered `304`
  with that tag and its `Vary: Accept-Encoding`, where it was the whole
  answer again, since the route compared the request's tags with the one
  it set before the answer was compressed. A static site served with
  `compress` was downloaded whole on every visit.

## 0.4.0 (2026-10-13)

- Breaking: `spindle_postgres` needs rowtype 0.6.0 and postgres-eio
  0.4.0. A unique, exclusion or foreign-key constraint declared
  `DEFERRABLE` that refuses a transaction's `COMMIT` is
  `` `Conflict `` with the constraint's name, as one a statement finds is,
  so a route's `` `Conflict `` arm answers it with the code it declares,
  where it was `` `Not_committed `` and answered `500`.
  `Rowtype_postgres.Conninfo.t` is a private record: set a database or a
  connect timeout with `Conninfo.with_database` or
  `Conninfo.with_connect_timeout`.

- Breaking: `spindle` needs wiretype 0.4.0, which changes what
  `Spindle.Openapi` and `Spindle.Zod` write for some types: a derived
  type with parameters is written where it is used, not as one shared
  component, unless `[@@kind]` names it; and kinds that hold each other
  in a ring of three or more refer to each other, where the member
  closing the ring was any JSON. A JSON body whose map key is read in
  more than one spelling -- a `uuid` in either case -- is refused when it
  gives one key twice.

- A WebSocket send's `send_timeout` runs from the last byte the peer took,
  as an answer's does, where it ran afresh for each 16 KiB written: a
  peer reading a large message steadily below about 546 bytes a second
  was cut off as `Lost`. One that stops taking anything still is, up to a
  tenth of the limit late.

- `Spindle.Refusal.busy` writes a `Retry-After` of at least one second,
  as `rate_limited` does, where a `retry_after_s` below one was written
  as it came, and a negative one is no `Retry-After` RFC 9110 allows.

- `Spindle.Rate.create` raises `Invalid_argument` for a `per` shorter
  than `limit` nanoseconds, which left no time between two calls and so
  limited nothing. Not breaking in practice: no limit that worked is
  refused.

- Breaking: `App.make` refuses a JSON answer under `204` or `205` --
  `` Returns.json ~status:`No_content `` or either listed in
  `Returns.json_response`'s `statuses` -- which HTTP sends without a body,
  so the document promised JSON the wire dropped. Only a table that was
  already wrong stops starting: declare such an answer with
  `Returns.empty` or `Returns.empty_response`.

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

- A `Response.stream` sent from several fibers at once sends one after
  another, as an event stream's filler and producer already did, and
  `send_timeout` ends every one of them: two sends at once could leave
  one waiting for ever on a client that stopped reading, holding its
  connection slot.

- `Path.url` writes a segment of `.` or `..` as `%2E` or `%2E%2E`, where
  it wrote it as it was, and a browser resolved `/users/..` to `/`.

- **Breaking:** `Key.sign` and `Key.seal` use keys of their own, derived
  from the secret apart from a signed and an encrypted cookie's, so a
  token an application signs or seals over text a caller chose is never
  a cookie: `Key.sign` over a signed cookie's payload was a valid cookie,
  and `Key.seal` an encrypted one. A token `Key.sign` or `Key.seal` made
  before no longer verifies or opens; cookies are made and read as
  before.

- **Breaking:** under `Cors.Any`, a write from another site carrying an
  `Authorization` in a scheme a browser caches and sends by itself --
  `Basic`, `Digest`, `Negotiate`, `NTLM` -- or one that is no credentials
  is `403 cross_origin`, as one carrying a `Cookie` was: a form another
  site posts is never preflighted and rides a cached login as it does a
  session. A `Bearer` token, or any other scheme a page sets itself, is
  served as before.

- **Breaking:** `App.make` refuses a `Returns.json ~status` or
  `Returns.empty ~status` that is not `2xx`, as it refused one listed in
  `Returns.json_response`, and a `Refusal.Code` whose status is not `4xx`
  or `5xx`, wherever it is declared: the OpenAPI document could give such a
  route two answers under one status, and a refusal answered `200` read as
  a success. A redirect is `Returns.response` with `Response.redirect`.

- **Breaking:** `Cookie.signed` and `Cookie.encrypted` take
  `~max_age:Mtime.Span.t` where they took `~max_age_s:int`, as
  `Session.create` takes its spans: it is a bound the server holds a
  cookie to, not only the `Max-Age` it writes, which is the span in whole
  seconds rounded up. `Cookie.make ?max_age_s` is that field and stays a
  number of seconds.

- **Breaking:** `Spindle.Test.response`'s `status` is a
  `Spindle_http.Status.t`, as every other status in the API is, where it
  was an `int`: a test compares `Spindle_http.Status.to_int r.status`, or
  matches `` `OK ``.

- **Breaking:** a form's files are read by `Form.File.required`,
  `Form.File.optional` and `Form.File.list`, each a `Form.File.t`, as
  its fields are by `Form.required`, `optional` and `list`, where they
  were `Form.file`, `Form.file_opt` and `Form.files`, each a `Form.file`.

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
