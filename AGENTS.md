# AGENTS.md

Spindle is an OCaml library of Hypha Stack, and keeps PRDs: a web
framework for OCaml 5 and Eio: typed routes, dependencies and answers,
and HTTP/1.1 read and written by itself. This file is for anyone changing
it, human or agent. Users start at [README.md](README.md) and the
documentation site, [docs/](docs/src/content/docs/index.mdx).

## Commands

```sh
make setup   # once: the switch hypha-spindle, every dependency
make test    # starts the test Postgres in Podman, runs every suite
make lint    # formatting, odoc, the release build, and the opam files
make fmt     # format in place
make docs    # the documentation site into _build/docs, as Pages publishes it; docs-serve serves it
```

`make test` needs `podman compose` and Bun 1.3 or later, which runs the
OAuth suite's authorization server, and `make docs` Bun. Without
`SPINDLE_TEST_PG` the suites that need a server are skipped, and without
`SPINDLE_TEST_OIDC` the rows that need the authorization server, and the
test output says so. CI runs `make lint` and `make test`, against the same
compose Postgres, on OCaml 5.5, and `make test` again on the oldest
versions the opam files allow. `docs.yml` publishes the site to GitHub
Pages on every push to `main`.

## Layout

```
http/       spindle-http: HTTP as both ends speak it -- heads, bodies,
            fields, dates, structured fields, multipart, the wire
core/       spindle: routes, dependencies, answers, refusals, cookies,
            logging, streams, WebSockets, the routes described as OpenAPI
client/     spindle-client: calling another server, on http/ alone
postgres/   spindle-postgres: a server's Postgres, over rowtype's backend,
            and its sessions table's migration
sqlite/     spindle-sqlite: a server's SQLite, over rowtype's backend, and
            its sessions table's migration
cli/        spindle-cli: the API, described on the command line
mcp/        spindle-mcp: an MCP server, routes a battery adds, on spindle's
            public interface alone
mcp-client/ spindle-mcp-client: calling another server's tools, on client/
            alone, and MCP's messages in protocol/, which both ends share
docs/       the documentation site, a Starlight site in Hypha's look, from
            starlight-theme-hypha: its pages in src/content/docs/, each
            importing the examples it shows as @examples/<file>?raw into
            Starlight's <Code>
examples/   the programs the site shows, each a whole file, built and run
test/       the suites: the framework, HTTP and WebSocket rows by RFC
            section, OAuth's by RFC, MCP's by the specification's
            section and access control's by OWASP ASVS's, the wire, the Postgres and SQLite kits, and test_docs,
            every example on a page
prds/       the PRDs of work being decided and built, by PRD.md, and its
            README.md: which document owns each fact once the work lands
```

Each module's contract is its `.mli`. Read the `.mli` before changing a
module.

## Where a fact goes

| | |
|---|---|
| A module's contract | its `.mli`, in odoc markup |
| What a contributor must not break | *Rules that must hold* below: an instruction, its reason in a clause and how you find out you broke it |
| How to use it | the documentation site, [docs/](docs/src/content/docs/index.mdx), every program imported whole from `examples/` |
| Why it changed | the commit message |

Code cites no document.

## Rules that must hold

Each is an instruction, its reason in a clause, and the way you will find
out you broke it, as it is true today. Cite one by its bold phrase.

- **`invalid_arg` is raised in these places alone**, each refusing a
  constant written in source, so a program that starts never meets one:
  `Spindle.Cookie.named`, `signed`, `encrypted` and
  `Spindle.Session.create` (for the name), `Spindle.Cookie.make` and
  `clear` (for a path), `Spindle_postgres.Session`'s and
  `Spindle_sqlite.Session`'s (for a table's name that is no identifier,
  since it is written into each statement),
  `Spindle.Metrics`'s registrations (for a name, a label or buckets
  Prometheus cannot read, or a name registered twice),
  `Spindle.Broadcast.create` (for a depth below one), `Spindle.Compress.make`
  (for a level deflate has not, a negative size, or a type that is no media
  type pattern), `Spindle.Rate.create` (for a limit or a burst below one, or a
  period shorter than a nanosecond a call), `Spindle.Bearer.make` (for an
  issuer or a resource that is no https URL without a query or a fragment)
  and `Spindle.Bearer.scope` (for a scope that is no RFC 6749
  scope-token), `Spindle_client.Oauth.create` (for a metadata document that
  is no https URL with a path), `Spindle_mcp.routes` (for two tools of one name, a name MCP
  refuses, arguments whose description is no object, a scope with no
  `~auth`, or a question that is no form or two of one key on a tool),
  `Spindle.Query.default` and `Spindle.Header.default` (for a default its
  description will not write), `Spindle.Server.Limits.make` and
  `Spindle.Route.Limits.make` (for a limit out of its range), `Spindle.Server.run`, `serve_on` and
  `Spindle.serve` (for fewer than one domain, or a trusted proxy that is no
  address), `Spindle.serve` and
  `Spindle.Test.app`, for a route table `App.make` refuses -- and `Test.app`
  for a `Static.directory` or a `Files.directory`, which a test has no
  filesystem to read, or for resources `App.start` refuses --, and
  `Spindle.Openapi.routes`, for whatever `Spindle.Openapi.make` refuses;
  and `Spindle.Test.call`, `Spindle.Test.events` and
  `Spindle.Test.websocket`, which refuse an undeclared code, a status its
  route does not list, a resource `Test.app` was not given, or a body read
  whole under a `max_body` the `body_budget` cannot hold -- and
  `Test.events` an event past its reader's limit -- in a test and nowhere
  else. Nothing else raises
  across a library boundary. Symptom: `rg -n -w invalid_arg -g '*.ml' http
  core client postgres sqlite cli` finds one this list does not name.
- **Spindle prints and exits in these places alone.** `Spindle.serve`
  prints the address it listens on unless given `?ready`, and exits with
  status 1 when its application cannot start or it cannot listen, as
  `Spindle_postgres.Pool.run` and `Spindle_sqlite.Pool.run` do when a pool
  cannot open, since a server missing what it needs is stopped where an orchestrator sees it --
  saying why in the log, or on stderr where the program set no log up,
  since Logs drops every line until it is;
  `Spindle.Log`'s default sink writes its lines to stderr; and
  `spindle-cli`, a command line, prints its answer and its errors and
  exits with its status. Symptom: `rg -n -w
  'exit|stderr|print_string|print_endline|prerr_endline|Printf\.printf'
  -g '*.ml' http core client postgres sqlite cli` finds one in a place this
  list does not name.
- **Spindle reads and writes HTTP itself, names no driver, and its client
  installs and links no framework.** No library links another HTTP
  implementation or names one; `spindle-postgres` and `spindle-sqlite`
  reach their database through rowtype's backends alone, so a second driver
  is a second backend and no change here; `spindle-client`, `spindle-http`
  and `spindle-mcp-client` are packages of their own, the clients linking
  `spindle-http` and never `spindle`, so a program that calls other servers,
  or their tools, installs and compiles no framework; and `spindle` never
  links a client, so a server that calls nobody compiles no TLS. Symptom: `rg -n -i -w
  'cohttp\w*|httpun\w*|httpaf\w*|h1|h2|piaf|paf|ezcurl|postgres.eio|sqlite3'
  -g '*.{ml,mli}' -g dune http core client postgres sqlite cli` finds a
  name, `rg -n '^ *spindle$' client/dune` finds the framework, `rg -n
  spindle_client core/dune` finds the client, `rg -n '^ *spindle$'
  mcp-client/dune` finds the framework, or `make lint`'s build of `spindle-http`,
  `spindle-client` and `spindle-mcp-client` alone fails.
- **A route is one value, and a dependency hands over an input.** A method
  and a path are declared together (`Spindle.post Path.(...)`), so a route no
  method can reach cannot be written. Every input a request carries -- a
  path parameter included -- is a dependency, and nothing else reads the
  request, so what a route reads can be listed. Symptom: a route that reads the request
  outside a dependency, so its document does not list what it reads.
- **A dependency value runs once per request**, unless read through
  `Dep.uncached`: every value but `Dep.return` and `Dep.both` has an
  identity, and every use of it in a request is given its first answer,
  through `Dep_repr.exec`, which is the only thing that runs one. A value
  lists the identities it is made of, so what a route reads is listed once
  and a route that reads nothing twice keeps no table. Test: a
  signed-in person read twice from the database, or an input listed twice
  in the document; `test_spindle` counts both.
- **A cookie that does not read is absent, never an error** -- one that
  fails its signature, its seal or its age, or a plain one its description does
  not read -- and a sealed one's age is held by the server as well as the
  browser: a browser holding one from a retired key, an old visit or an
  older deploy did nothing wrong,
  and a copied one would otherwise replay for ever. A signed or sealed value
  is bound to its cookie's name and stamped from the application's `now` as
  the answer is written. Test: a `400` for a cookie an old deploy made, or
  a value moved from one cookie to another reading as it; `test_spindle`'s
  cookie cases edit, move, age and rotate one.
- **A rate limit is a dependency**, so a route's `429` is in its document and on
  no route without one: `Rate.limit` declares `Refusal.Code.rate_limited`,
  which is not among the framework's codes every route may give. Test: a
  document that promises every route may answer `429`, or a limit a reader
  of the route cannot see; `test_spindle`'s rate case reads the document.
- **A setting has one name at every level.** A setting a route, an input
  or an answer overrides has the name and the type of the application's --
  `~compress`, `~cors`, `~refuses`, and `~limits`' `max_body`,
  `body_timeout`, `min_body_rate` and `handler_timeout` -- and one that
  exists at one level only has no twin under another name, because a
  reader who knows one level then knows the other. A route's settings are
  labels on the route, never an open map. Symptom: a route label or an
  input's argument whose name is not the application's for the same
  setting, a type that differs under one name, or a framework setting
  read from anywhere but a route's labels.
- **Who may call a route is what it reads.** A caller or a check of
  `Access` -- or `Bearer.claims` or `Bearer.scope`, whose subject is a
  caller -- is a dependency, and a route that reads none is anyone's, with
  no mark and no other mechanism, because access control is the
  application's choice and costs nothing until it is made. `Route.info`
  lists each, the document prints it, and `Access.unguarded` names the
  routes that read none, for an application's test to hold. Test:
  `test_access` reads each route's list and the unguarded ones; a route
  whose access is decided anywhere but its dependencies is this rule
  broken.
- **A guarded object reaches a handler only through its check.**
  `Access.resource` keeps the object's loader and `Access.can` is the only
  value that hands the object over, because an object read beside its check
  is a check skipped. Symptom: `rg -n 'resource ->' core/access.mli` finds
  a value other than `can`.
- **A secret has no span.** No header value, body, query string, statement
  parameter or message of an exception the framework did not catch by name
  is a span's attribute, as none is a log field: a request's span carries
  its access line's fields, a call's where it went and never its query, a
  statement's its text, and such a raise is told by its kind and its stack,
  since its message is whatever its raiser wrote; an I/O error caught by
  name keeps its words, which hold no data. A span's name is a route, a
  method, `postgresql` or `sqlite`, never a path or a string a caller
  chose, since a name per URL is a series per URL in every
  collector. A bearer token and its claims are in no line, a refusal's
  detail naming the check that failed and nothing of the token; a denial's
  line names its caller by the id the application's `Access.principal ~id`
  gives -- its own identifier, never a token's claim -- since an audit that
  names nobody is no audit. Test: a
  token in a collector, or a card number in a log line;
  `test_spindle` sends one in a header and a query and searches every
  attribute of the trace, and raises one from a handler, a stream and a
  socket and searches every line, and `test_oauth_rfc` sends a token that
  passes and one that fails and searches every line for either.
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
  framework's is a response desync. Test: a body's bytes answered as a
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
- **An OAuth rule is a row.** A requirement of RFC 6749, 6750, 7515, 7517,
  7518, 7636, 8037, 8252, 8414, 8707, 9068, 9207 or 9728 that Spindle meets,
  as a resource server, in fetching an issuer's keys or in signing a person
  in, has a row in `test_oauth_rfc`, named by
  its RFC and section; each RFC's published example is verified as it is
  printed, and its issuer rows take real tokens from node-oidc-provider,
  OpenID Certified, which `make test` runs. Spindle follows the RFC, not
  what other implementations tolerate: a requirement an issuer skips is
  still checked. Symptom: a token accepted that a MUST refuses, which no
  token of ours happened to break.
- **A token is checked against its audience.** No bearer token is accepted
  whose `aud` does not name the resource, whose `typ` is not `at+jwt`, or
  whose `alg` is `none` or an HMAC, since a token issued for another server,
  an ID token, or one signed with a key both ends hold is the confused
  deputy RFC 8707 and RFC 9068 §4 guard against. Test: `test_oauth_rfc`'s
  rows refuse each, and the issuer's token for another resource.
- **A value is validated by its wiretype description.** A path segment, a
  query parameter, a header, a cookie and a form's field are each read by a
  `Wiretype.t`, through `Wiretype.of_text`, and written through `to_text`:
  a scalar's grammar, a bound, an enum's words and a kind are wiretype's, so
  a parameter and a body's member cannot disagree, as FastAPI hands
  pydantic its parameters; what stays Spindle's is HTTP's own -- a header's
  lines, and its structured values, each a `Wiretype.kind` over
  `spindle_http`'s parser. Symptom: `rg -n -w
  'int_of_string_opt|float_of_string_opt' core/input.ml core/form.ml
  core/path_repr.ml core/query.ml core/header.ml` finds a grammar of
  Spindle's, or `007` is read in a query and refused in a body.
- **A value with structure is read by its parser.** Inside Spindle,
  a header whose value has a structure `spindle_http` reads -- a list, a
  media type, credentials, `Accept`, `Cache-Control`, `Forwarded`, a
  Structured Field -- is read by that module and never split or searched
  with string functions, and a query string is read by `Urlencoded`, never
  by `Uri.query`, which splits a value at its commas, because two readings
  of one value is how a proxy and a server come to disagree. Symptom: a
  `String.index_opt v ';'` on a header, or `rg -n
  'Uri\.(query|get_query_param)\b' -g '*.ml' http core client postgres
  sqlite cli` finds a call.
- **A WebSocket rule is a row.** A requirement of RFC 6455 that Spindle
  meets, as a server or as a client, has a row in `test_websocket_rfc`,
  named by its section and read whole, a byte at a time and at splits a
  generator chooses, through a reader smaller than a frame.
  Symptom: a frame one end misreads that no peer in the suite happens to
  send -- as a reply written after a close was, until a row asked.
- **An access rule is a row.** A requirement of OWASP ASVS 5.0's V8,
  Authorization, that Spindle meets has a row in `test_access`, named by its
  number, and each row is seen failing when the check it guards is broken.
  Review by example misses the requirement nobody thought of. Symptom: a
  denial no row of ours happened to make -- a check a header or a path's
  spelling skips.
- **An MCP rule is a row.** A requirement of MCP 2026-07-28 that Spindle
  meets, as a server or as a client, has a row in `test_mcp_spec`, named by the specification's page and
  section, as does one of JSON-RPC 2.0 as MCP uses it. Review by example
  misses the requirement nobody thought of. Symptom: an answer an MCP
  client refuses that no row of ours happened to send.
- **An MCP server keeps nothing between requests.** No table of sessions or
  clients: 2026-07-28 has none, each call is answered on its own, and what
  spans calls is a handle the application mints. A server of several domains,
  or behind a balancer, has no other way to be right. Symptom: a
  `Hashtbl` or a `ref` in `mcp/` that outlives a request.
- **A battery uses the framework's public interface alone.** `spindle-mcp`
  names nothing of `spindle` its `.mli` files do not export, so it is a
  battery anyone outside could have written, and what it needs and cannot
  reach is a gap in the framework, closed there. Symptom: `rg -n
  '_repr|Private' mcp` finds a name.
- **A socket's failures are values, and so are a stream's.**
  `Websocket.receive`, `Websocket.send` and an events stream's `send` answer
  results, a socket's handler and caller return one, and how a handler's
  loop ended decides its close; nothing in the framework raises into the
  application or cancels a handler whose peer has gone -- it learns at its
  next `receive` or `send`, or sooner by waiting on `Spindle.client_gone`,
  which the server resolves and the handler reads as a value. The one
  cancellation is a handler past its `handler_timeout`, before its answer
  is in hand, and a transaction under it ends with nothing kept. Symptom: a
  `try` around a send, or work stopped mid-transaction under a handler that
  was within its limit.
- **A release cannot be cancelled.** Whatever gives a resource back -- a
  subscription to its `Broadcast` hub -- takes its lock under
  `Eio.Cancel.protect`, and `Broadcast.subscribe` releases on every way out
  of its function, since a release often runs in a fiber already cancelled,
  where waiting for a lock another domain holds raises and the resource is
  never given back: a subscriber listed after its client left, and its queue
  held for as long as its topic stays quiet. Test: `test_spindle` cancels
  2,000 subscribers while another domain holds the hub's lock, and finds
  none left.
- **A file is read for a request only by `Static`'s lookup or beneath a
  `Files` directory's subtree**, never by a path joined from a request:
  `Static` reads its files when the server starts and answers from memory,
  and `Files` refuses a segment that steps anywhere before it opens
  anything, then opens beneath `Eio.Path.with_subtree`, which the operating
  system holds to the directory. Test: `/../` or a symlink reaching a
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
  `idle_timeout`
  between requests, `head_timeout` from a head's first byte, and
  `body_timeout` from a body's first read moved a second on for every
  `min_body_rate` bytes; while an answer is written, `send_timeout`
  from the last byte the client took, so a client still reading slowly is
  never cut off and one that stops is; and `linger` while a closing
  connection's last bytes are read and dropped. A deadline passes up to a
  tick late, and a tick is a tenth of the shortest limit.
  A client that stops is otherwise a fiber and a connection slot held until
  the process ends, and a wait re-armed on every byte holds one for as long
  as the body's length allows. The server owns its connection's writer for
  this: Eio's `Buf_write.with_flow` flushes before an exception leaves it,
  which to a client that is not reading never returns. Test:
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

## Changes and releases

Its packages are `spindle-http`, `spindle-client`, `spindle`,
`spindle-mcp-client`, `spindle-mcp`, `spindle-postgres`, `spindle-sqlite` and
`spindle-cli`. A
user-visible change updates the page of the documentation site that
describes it, not the README. Two variants are closed, from 1.0:
`Spindle_http.Status.t` and `Spindle_http.Meth.t` name every status and
method HTTP defined by then, and one registered later stays
`` `Code n `` or `` `Other s `` for every 1.x release, so a match on
either keeps its meaning across them. A refusal's sentence is wording; a
refusal's code, a route's place in the document and what the OpenAPI,
Zod and Melange printers write for a route are behaviour: changing any is
breaking.
