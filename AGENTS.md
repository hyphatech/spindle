# AGENTS.md

Spindle is a web framework for OCaml 5 and Eio: typed routes, dependencies
and answers, and HTTP/1.1 read and written by itself. This file is for
anyone changing it, human or agent. Users start at [README.md](README.md)
and the documentation site, [docs/](docs/index.md).

## Commands

```sh
make setup   # once: local opam switch in ./_opam, every dependency
make test    # starts the test Postgres in Docker, runs every suite
make lint    # formatting, odoc, the release build, and the opam files
make fmt     # format in place
make docs    # the documentation site into site/, as Pages publishes it; docs-serve to preview
```

`make test` needs `docker compose`. Without `SPINDLE_TEST_PG` the suites
that need a server are skipped, and the test output says so. CI runs `make
lint` and `make test`, against the same compose Postgres, on OCaml 5.5, and
`make test` again on the oldest versions the opam files allow. `docs.yml`
publishes the site to GitHub Pages on every push to `main`.

## Layout

```
http/       spindle.http: HTTP as both ends speak it -- heads, bodies,
            fields, dates, structured fields, multipart, the wire
core/       spindle: routes, dependencies, answers, refusals, cookies,
            logging, streams, WebSockets, the routes described as OpenAPI
client/     spindle.client: calling another server, on http/ alone
postgres/   spindle_postgres: a server's Postgres, over rowtype's backend
cli/        spindle_cli: the API, described on the command line
docs/       the documentation site, every program included from examples/
overrides/  the site's theme overrides: the header's mark, as an icon
examples/   the programs the site shows, each built and run
test/       the suites: the framework, HTTP and WebSocket rows by RFC
            section, the wire, the Postgres kit, and test_style, the house
            rules that can be checked mechanically
```

Each module's contract is its `.mli`. Read the `.mli` before changing a
module.

## Where a fact goes

| | |
|---|---|
| A module's contract | its `.mli`, in odoc markup |
| What a contributor must not break | *Rules that must hold* below: an instruction, its reason in a clause and how you find out you broke it |
| How to use it | the documentation site, [docs/](docs/index.md), every program included from `examples/` |
| Why it changed | the commit message |

Every document describes today: a change that makes a sentence false edits
that sentence in the same commit. Code cites no document.

## Rules that must hold

Each is an instruction, its reason in a clause, and the way you will find
out you broke it, as it is true today. Cite one by its bold phrase.

- **No partial functions, and `invalid_arg` only where the `.mli` says it
  raises.** Errors are values. The exceptions each refuse a constant written
  in source: `Spindle.Cookie.named`, `signed`, `encrypted` and
  `Spindle.Session.create` (for the name), `Spindle.Cookie.make` (for a value
  its codec prints that no cookie can hold, or a path) and `clear` (for a
  path), `Spindle_postgres.Session`'s (for a table's name
  that is no identifier, since it is written into each statement),
  `Spindle.Cors.make` (for `Any` beside credentials, which the Fetch standard
  refuses), `Spindle.Metrics`'s registrations (for a name, a label or buckets
  Prometheus cannot read, or a name registered twice) and its counting (for
  a number of label values other than its family's, or a counter moved
  down), `Spindle.Broadcast.create` (for a depth below one),
  `Spindle.Compress.make` (for a level deflate has not, or a negative
  size), `Spindle.Rate.create` (for a limit or a burst below one, or a
  period that is no positive number of seconds),
  `Spindle.Server.run`, `serve_on` and `Spindle.serve` (for a limit out of
  its range, or a trusted proxy that is no address), `Spindle.serve` and
  `Spindle.Test.app`, for a route table `App.make` refuses -- and `Test.app`
  for a `Static.directory`, which a test has no filesystem to read --, and
  `Spindle.Openapi.docs`, for one or a description its document cannot name;
  and `Spindle.Test.call`, `Spindle.Test.events` and
  `Spindle.Test.websocket`, which refuse an undeclared code, or a status its
  route does not list -- and `Test.events` an event past its reader's
  limit -- in a test and nowhere else. Nothing else raises
  across a library boundary. Symptom: `test_style` names the line, and
  its list of exceptions is this one.
- **Spindle reads and writes HTTP itself, names no driver, and its client
  links no framework.** No library links another HTTP implementation or
  names one; `spindle_postgres` reaches Postgres through rowtype's backend
  alone, so a second driver is a second backend and no change here; and
  `spindle.client` links `spindle.http` and never `spindle`, so a program
  that calls other servers compiles no framework. Symptom: `test_style`'s
  boundaries.
- **A route is one value, and a dependency hands over an input.** A method
  and a path are declared together (`Spindle.post Path.(...)`), so a route no
  method can reach cannot be written. Every input a request carries -- a
  path parameter included -- is a dependency, and nothing else reads the
  request, so what a route reads can be listed.
- **A dependency value runs once per request**, unless read through
  `Dep.uncached`: every value but `Dep.return` and `Dep.both` has an
  identity, and every use of it in a request is given its first answer,
  through `Dep_repr.exec`, which is the only thing that runs one. A value
  lists the identities it is made of, so what a route reads is listed once
  and a route that reads nothing twice keeps no table. Symptom: a
  signed-in person read twice from the database, or an input listed twice
  in the document; `test_spindle` counts both.
- **A cookie that fails its signature, its seal or its age is absent, never
  an error**, and its age is held by the server as well as the browser: a
  browser holding one from a retired key or an old visit did nothing wrong,
  and a copied one would otherwise replay for ever. A signed or sealed value
  is bound to its cookie's name and stamped from the application's `now` as
  the answer is written. Symptom: a `400` for a cookie an old deploy made, or
  a value moved from one cookie to another reading as it; `test_spindle`'s
  cookie cases edit, move, age and rotate one.
- **A limit is a dependency**, so a route's `429` is in its document and on
  no route without one: `Rate.limit` declares `Refusal.Code.rate_limited`,
  which is not among the framework's codes every route may give. Symptom: a
  document that promises every route may answer `429`, or a limit a reader
  of the route cannot see; `test_spindle`'s rate case reads the document.
- **A secret has no span.** No header value, body, query string or
  statement parameter is a span's attribute, as none is a log field: a
  request's span carries its access line's fields, a call's where it went and
  never its query, and a statement's its text. A span's name is a route, a
  method or `postgresql`, never a path or a string a caller chose, since a
  name per URL is a series per URL in every collector. Symptom: a token in a
  collector; `test_spindle` sends one in a header and a query and searches
  every attribute of the trace.
- **Spindle frames every body, and its connection loop is the only thing
  that reads a socket.** A connection carries another request only once the
  last one's body was read to its end -- a route that ignored it has it
  discarded, and one with too much left closes -- and a framing RFC 9112
  forbids is refused, because a body that ends in the wrong place is read as
  the next request, which behind a proxy is somebody else's. A route reads
  its body through the dependency the loop hands it, and no other way --
  whole, or as it arrives, one of the two and only while its handler runs,
  because once it returns the loop reads the connection for the next
  request. And
  the server writes every field that says how an answer is framed or whether
  its connection lasts -- `Wire.render` and the loop, nothing else: a
  response that sets one itself, or answers a final status outside 200–599,
  is the route's bug and answered `500`, because a second length beside the
  framework's is a response desync. Symptom: a body's bytes answered as a
  second request, or two `Content-Length`s on one answer; `test_wire` sends
  several requests down one connection to catch it, and `test_http_rfc` a
  thousand random sequences, handlers that frame themselves among them.
- **An HTTP rule is a row.** A requirement of RFC 9112 or RFC 9110 that
  Spindle meets has a row in `test_http_rfc`, named by its section and read
  whole, a byte at a time and at splits a generator chooses -- a field
  value, a string already in hand, whole -- and so has one of RFC 9111 §5.2
  and RFC 7239; RFC 9651 is its published suite, kept in
  `test/structured-field-tests/` and run whole by `test_structured`; and
  RFC 7578's and RFC 2046's, the multipart a form is posted as, are
  `test_multipart_rfc`'s, read the same three ways. Review by example misses the requirement nobody thought of.
  Symptom: a MUST nobody noticed, which is how the missing `Host` check was
  found.
- **A value with structure is read by its parser.** Inside Spindle,
  a header whose value has a structure `spindle_http` reads -- a list, a
  media type, credentials, `Accept`, `Cache-Control`, `Forwarded`, a
  Structured Field -- is read by that module and never split or searched
  with string functions, because two readings of one value is how a proxy
  and a server come to disagree. Symptom: a `String.index_opt v ';'` on a
  header.
- **A WebSocket rule is a row.** A requirement of RFC 6455 that Spindle
  meets, as a server or as a client, has a row in `test_websocket_rfc`,
  named by its section and read whole, a byte at a time and at splits a
  generator chooses, through a reader smaller than a frame.
  Symptom: a frame one end misreads that no peer in the suite happens to
  send -- as a reply written after a close was, until a row asked.
- **A socket's failures are values, and so are a stream's.**
  `Websocket.receive`, `Websocket.send` and an events stream's `send` answer
  results, a socket's handler and caller return one, and how a handler's
  loop ended decides its close; nothing in the framework raises into the
  application or cancels a handler whose peer has gone -- it learns at its
  next `receive` or `send`, or sooner by waiting on `Spindle.client_gone`,
  which the server resolves and the handler reads as a value. Symptom: a `try` around a send, or work stopped
  mid-transaction under a handler.
- **A file is read for a request only by `Static`'s lookup or beneath a
  `Files` directory's subtree**, never by a path joined from a request:
  `Static` reads its files when the server starts and answers from memory,
  and `Files` refuses a segment that steps anywhere before it opens
  anything, then opens beneath `Eio.Path.with_subtree`, which the operating
  system holds to the directory. Symptom: `/../` or a symlink reaching a
  file outside; `test_spindle`'s files cases send both.
- **`localhost` and a wildcard bind both families.**
  `localhost` resolves to `::1` as well as `127.0.0.1`, and browsers prefer
  IPv6; a container's port is forwarded over either. `Spindle.Server.run` is
  the one place a port is bound: `localhost` binds both loopback addresses
  whatever the resolver says, `0.0.0.0` and `::` every interface of both,
  and listening beyond loopback is only ever `run`'s `~host`, written where
  the server starts. Symptom: `fetch()` fails while `curl` works, or
  `Connection refused ... tcp:[::1]`.
- **Every wait on a client is bounded, and a body by a rate as well as a
  wait.** A connection has one deadline, moved on only as it makes progress,
  and every read of it runs against it (`Deadline`), with one sweep per
  domain looking at all of that domain's, so moving one is a field and never
  a timer:
  `idle_timeout_s`
  between requests, `head_timeout_s` from a head's first byte, and
  `body_timeout_s` from a body's first read moved a second on for every
  `min_body_rate` bytes; and while an answer is written, `send_timeout_s`
  from the last byte the client took, so a client still reading slowly is
  never cut off and one that stops is. A deadline passes up to a tick late,
  and a tick is a tenth of the shortest limit.
  A client that stops is otherwise a fiber and a connection slot held until
  the process ends, and a wait re-armed on every byte holds one for as long
  as the body's length allows. The server owns its connection's writer for
  this: Eio's `Buf_write.with_flow` flushes before an exception leaves it,
  which to a client that is not reading never returns. Symptom:
  `max_connections` clients that never read, or a connection slot held by a
  byte a minute; `test_spindle` holds one slot with one, and `test_wire`
  cuts off a body sent a byte a second.

- **A test's verdict never turns on how fast the machine is.** What must
  happen is waited for -- a promise, a condition, the end of a connection
  -- and never given a deadline; what a server does in time is tested on
  `In_memory`'s virtual time, where a client's pause is the test's to say
  and a read the server makes wait is a failure, not a slow answer; work
  that must outlast a deadline never ends rather than sleeping past it. A
  timer that decides a verdict measures the runner, which a loaded one
  stretches. Symptom: a test green on a laptop and red on a loaded CI
  runner.

## House style

The house style, the OCaml checklist and the OCaml tools are
[OCAML.md](OCAML.md), the same in every Hypha OCaml repository and changed
in all of them together, never in one. It is imported here, so it is read
with this file:

@OCAML.md

## Git

How work becomes a commit -- its format, where it happens, what is pushed
-- is [GIT.md](GIT.md), the same in every Hypha repository and changed in
all of them together, never in one. It is imported here, so it is read
with this file:

@GIT.md

## Changes

- A user-visible change adds a line under `## Unreleased` in
  [CHANGES.md](CHANGES.md), in the same commit. A breaking one says so.
- A change that makes a sentence in a document false edits that sentence in
  the same commit.
- A user-visible change updates the `.mli` it touches and the page of the
  documentation site that describes it.

## Releases

[Semantic Versioning 2.0.0](https://semver.org). Before 1.0, a breaking
change bumps the minor version and anything else the patch. The three
packages are released together, at one version.

Breaking means a user's code may stop compiling or behave differently:
removing or renaming anything in an `.mli`, changing a type, adding a
constructor to a public variant (it breaks exhaustive matches), adding a
required argument, or changing a default or documented behaviour. Adding a
function, a module or an optional argument is not breaking, and neither is
the wording of a refusal's sentence. A refusal's code, a route's place in
the document and what the OpenAPI and zod printers write for a route are
behaviour: changing any is breaking.

The version lives only in the git tag (`0.1.0`, no `v`). A release renames
`## Unreleased` in CHANGES.md to the version and date, and tags it. The GitHub
release notes are that entry with each paragraph and bullet on one line,
since GitHub keeps every line break in release notes.
