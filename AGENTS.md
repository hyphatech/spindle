# AGENTS.md

Spindle is a web framework for OCaml 5 and Eio: typed routes, dependencies
and answers, and HTTP/1.1 read and written by itself. This file is for
anyone changing it, human or agent. Users start at [README.md](README.md)
and the documentation site, [docs/](docs/index.md).

## Commands

```sh
make setup   # once: local opam switch in ./_opam, every dependency
make test    # starts the test Postgres in Docker, runs every suite
make lint    # formatting, odoc, and the release build
make fmt     # format in place
make docs    # the documentation site into site/, as Pages publishes it; docs-serve to preview
```

`make test` needs `docker compose`. Without `SPINDLE_TEST_PG` the suites
that need a server are skipped, and the test output says so. CI runs `make
lint` and the suites on OCaml 5.4 and 5.5, and the oldest versions the opam
files allow. `docs.yml` publishes the site to GitHub Pages on every push to
`main`.

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
  next `receive` or `send`. Symptom: a `try` around a send, or work stopped
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

<!-- hypha-ocaml: begin. Every Hypha OCaml repository carries this text word for word; a change to it is made to every copy together. -->
## House style

The goal is code that is beautiful from the inside: idiomatic, clean and
simple. An OCaml expert who has never seen the repository recognises every
pattern in it on sight and is surprised by nothing.

The rules are ranked, because they conflict:

1. **Simple and obvious beats clever.** If a reviewer has to reconstruct
   why something works, it is wrong even when it is correct.
2. **Locality of behaviour beats DRY.** Code that changes together lives
   together, and a function reads top to bottom without chasing helpers
   around the file. Code that only looks alike is not duplication when it
   changes for different reasons. Extract only for a rule that must hold
   in exactly one place, a boundary the code cannot cross -- two
   executables that must not link each other -- or a third copy that has
   already drifted.
3. **No layer without a job.** No abstraction with one implementation
   unless the signature is the point, no functor for a choice made once,
   no indirection added for symmetry. A 40-line function doing one thing
   beats four 10-line ones only ever called in sequence.
4. **Comments say why, never what**, in a sentence or two: the RFC or
   protocol section, a rule the code must keep, a constraint that is not
   visible, the measured reason for a number. Never history; that is the
   commits'. A comment that explains what the code does means the code is
   rewritten, and one the names already say is deleted.

### OCaml checklist

A change is done when every box holds:

- [ ] The checks under *Commands* pass.
- [ ] **Test first.** A behaviour starts as a test that fails for the
  reason the behaviour is missing -- an assertion against a stub, never a
  compile error -- and only then is the code written that makes it pass;
  a test never seen failing may test nothing. A bug's fix starts with the
  test that reproduces it. The test is the interface's first caller, so
  an awkward test is an awkward API. Then the corner cases (empty, one,
  the boundaries, invalid input, a failure partway through), a property
  wherever a round trip exists, and the real server wherever a test can
  run one, never a mock of it; a stub stands in only for a third party's
  service. A refactoring adds no test and keeps every one passing.
- [ ] **No partial functions**: nothing raises on an input the code has not
  ruled out. No `failwith`, `Option.get`, `Result.get_ok`, `List.hd`,
  `List.tl`, `List.nth`, `Obj.magic`, and `invalid_arg` only where the
  `.mli` says it raises and the repository's rules name it; a stdlib call
  that raises -- `String.sub`, an index, `Hashtbl.find`, `List.assoc`,
  `int_of_string`, `Char.chr`, `List.combine` -- only on an input already
  known to be in range, else its `_opt`.
- [ ] **Errors are values**: a `result` with a variant error, and `let*`
  over it rather than nested matches. Eio is direct-style, so `let*` always
  means `result`. An exception is a programmer's error and never crosses a
  library boundary. One a stdlib call raises is caught with `match ...
  with exception`, never a `try` around the code that uses the answer,
  which would catch that code's exceptions too.
- [ ] **No polymorphic `compare`, and no `=` on a type that has a
  module**: `Int.compare`, `String.equal`. `=` on `int` and `char` is fine.
  `List.mem`, `List.assoc`, `List.sort compare`, `max`, `min` and a
  `Hashtbl`'s keys are polymorphic too: accepted over plain data -- an
  `int`, a `char`, a `string` -- where nothing can hold a closure or an
  abstract type, and nowhere else. `==` only where identity is the point.
- [ ] **No `open` of an ordinary module**, file-wide or local: a reader
  cannot tell where a name came from, and a name the module gains later
  silently shadows one of ours. Alias it at the top of the file (`module P
  = Protocol`), and annotate a value's type once rather than qualify its
  fields (`(g : Store.game)`, then `g.size`, never `g.Store.size`). **A
  module made to be opened is opened**: one of binding operators and
  nothing else, file-wide (`open Spindle.Syntax`), and a library of
  combinators or operators locally, around the expression that uses them
  (`Angstrom.( ... )`, `Float.( ... )`). Any other `open` is one the
  repository's rules name, with its reason.
- [ ] **No silenced warnings.** The warning set in `dune` is the linter --
  warning 9 makes adding a record field a compile error at every pattern
  that should handle it -- and a warning that looks wrong is a code shape
  that is wrong.
- [ ] **Ergonomics is a requirement, never a polish**, and a refactoring or
  a new feature that ignores it is not done. It is judged where it is
  used -- the tests, the examples, the README, every caller -- as much as
  in its own module: the common case reads in one obvious line, a caller
  writes nothing the code could have known, a mistake is a compile error
  or a refusal that says what to do, every name, label and argument order
  is the one a caller would guess, and there is one way to do a thing: a
  new name never repeats what the caller can already say with the names it
  has. A change that leaves a caller's code longer, noisier or easier to
  get wrong is redone, however clean its inside. The shapes are the
  stdlib's: `t` for a module's own type and first among its arguments, a
  function before the collection it walks, `create`/`make`, `of_x`/`to_x`
  and `*_opt`; a label wherever two arguments could be swapped, and an
  optional argument with its default, followed by `()`.
- [ ] **An `.mli` per library module.** Abstract types, hidden
  constructors; the contract in odoc in the `.mli`, the reasons in the
  `.ml`. It exports what a user needs, and nothing more. **A library's
  user is whoever builds on it, not this repository**: an abstraction an
  application would reach for -- reading one query parameter, writing
  what a parser reads -- stays exported though nothing here calls it and
  its tests are its only caller, since a general-purpose library is
  judged by the applications it has not met yet. What no user would
  want -- a helper, a step of the implementation, a representation -- is
  not exported however convenient. An application's module has no user
  but its own code, and exports only what that code uses.
- [ ] **A library never prints or reads the environment, and exits only
  where its `.mli` says.** An executable reads its environment where it
  starts. A library logs on its own `Logs` sources.
- [ ] **A log line stands alone, and a secret has no log level.** A line
  says enough to be read among a thousand others and is never split
  across two. No header value, body, query string, credential or
  statement parameter is logged, at any level.
- [ ] **A meaning is a type.** A state is a variant, never a string, a
  boolean or a pair of booleans one combination of which is impossible; a
  unit or an identifier that travels unnamed -- a column, an element, a
  returned value -- is a type of its own, never a bare `int` or `string`
  whose meaning the caller has to remember. A labelled argument that names
  its unit at every call (`~timeout_s`) is enough.
- [ ] **Advanced types only where they delete real duplication.** A GADT
  earns its place by describing a thing once that would otherwise be
  described twice; otherwise, records and variants. A polymorphic variant
  only where the set of constructors is open by design, never to save
  declaring a type, and no objects.
- [ ] **Effects at the edge.** What can be computed without IO is, in code
  that does none, and a value is converted to and from a wire format at a
  boundary, never in the middle. An interface hands out immutable values;
  mutation inside an implementation is fine while it never escapes it.
- [ ] **Cancellation leaves nothing held.** A fiber cancelled at any effect
  releases what it held: a connection goes back to its pool or is closed,
  and a lock is let go. A catch-all handler (`with _ ->`,
  `| exception _ ->`) re-raises `Eio.Cancel.Cancelled` before anything else,
  or it swallows the cancellation.
- [ ] **A name says what a thing is or does, in the words a person would
  use where it is read.** No metaphors, moods or puns, and no
  abbreviations beyond the stdlib's (`b` a buffer, `n` a count, `f` a
  function). A rename earns itself at a use site: it is made only where a
  caller's reader misreads the current name or has to look it up, never
  because a rule can be cited for it, and never to tell apart two names
  the types already keep apart. A name assembled from parts to satisfy a
  rule (`renewals_per_idle`, `Call_failed`) is worse than none: where no
  natural name comes, the plainer one stays -- the one already there, or
  none. A name never repeats its module (`Pool.connection`, never
  `Pool.pool_connection`), says `get` only where something is fetched,
  and is as long as its scope is wide.
- [ ] **A number with a reason is named where nothing beside it already
  says it**, the reason beside it: a field, a label or a comment that
  names its unit and purpose (`send_timeout_s = 10.`) needs nothing more.
- [ ] **No needless cost.** No quadratic walk where a linear one is as
  clear, and no whole result held where streaming is as simple. Recursion
  over input whose size nobody bounds is a tail call, or
  `[@tail_mod_cons]`, since a deep stack is a crash rather than a slow
  answer. A claim about speed comes with a measurement.
- [ ] **A dependency earns its place**: it does something nothing already
  linked does, and the repository says what. Pure OCaml over a C
  binding; no Base, Core or Lwt.
- [ ] **`ocamlformat` decides layout.** Never format by hand; when its
  output is ugly, the code's shape is what is wrong.

## OCaml tools

Nothing is on PATH. Every OCaml tool runs through the repository's local
switch, `opam exec --switch=<root> --` from the repository's root, or
through the Makefile; no `eval`. `make setup` installs Merlin and
`ocaml-lsp-server` with the rest.

**The compiler's knowledge reaches an agent through `ocamllsp`**, where
`rg` matches text and a shadowed, re-exported or aliased name defeats it.
Run as the agent's language server, from the repository's own switch,
it answers every edit to OCaml source with its type errors, and its `LSP`
tool gives a name's definition, its references, tests included, its type
and a module's symbols. References read the index as the last build left
it, so after an edit rebuild it -- `dune build @check @ocaml-index` --
before asking.

**A worktree inside the checkout is its own dune root only with an
untracked `dune-workspace`**, holding the `dune-project`'s own `(lang dune
...)` line and kept out of version control. Without one dune takes the
checkout around it as the root and skips the hidden directory the worktree
is in, so the server and Merlin answer from no configuration: every module
unbound, one use of every name. For a single command, `DUNE_ROOT` set to
the worktree does the same.

**Without the language server, Merlin's command line answers the same**:
`ocamlmerlin single <query> -filename FILE < FILE`, in JSON, lines from 1
and columns from 0 -- `occurrences -identifier-at LINE:COL -scope
project`, `locate -position LINE:COL`, `type-enclosing -position LINE:COL`,
`outline`, and `errors`, which reads the file from standard input. Its
`occurrences` reads the index as the last `dune build @ocaml-index` left
it.

**Ask for a record field's uses from its definition in the `.ml` or from
a use**, never from its declaration in the `.mli`, which answers with that
declaration alone; a value asked from its `.mli` finds every use.

`dune describe` lists every library, executable and module, so nothing is
missed when the whole project is read.

**What a change touches is found by the compiler's knowledge**, never by
a text search: every caller of a changed signature and every user of an
export is the language server's references, or Merlin's `occurrences`.
**Ask `rg` everything else, always with a path** -- with none it reads
standard input, which an agent's shell never closes.

**Search with `rg`, never `grep -r` or `find`.** `_build/` and `_opam/` are
gitignored, so `rg` skips them, where `find . -name '*.ml'` also returns
every copy of the source under `_build/` and every package under `_opam/`.

`opam list --installed` says what the switch holds; `opam list
--required-by --recursive` resolves against what is available, not what is
installed.
<!-- hypha-ocaml: end -->

## Changes

- A user-visible change adds a line under `## Unreleased` in
  [CHANGES.md](CHANGES.md), in the same commit. A breaking one says so.
- A change that makes a sentence in a document false edits that sentence in
  the same commit.
- A user-visible change updates the `.mli` it touches and the page of the
  documentation site that describes it.
- Commit subjects are imperative, under 72 characters, with no full stop.
  The body says why, wrapped at 72. No trailers.

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
