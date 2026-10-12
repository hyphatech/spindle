# OCaml

<!-- Managed copy: kept word for word across Hypha's OCaml repositories. Do not edit it here; it is overwritten. -->

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
4. **A comment in an `.ml` says why, never what**, in a sentence or two:
   the RFC or protocol section, a rule the code must keep, a constraint
   that is not visible, the measured reason for a number. Never history;
   that is the commits'. A comment that explains what the code does means
   the code is rewritten, and one the names already say is deleted. What a
   value does is its `.mli`'s odoc, the contract a caller reads.

### OCaml checklist

A change is done when every box holds:

- [ ] The checks under *Commands* in `AGENTS.md` pass.
- [ ] **Test first.** A behaviour starts as a test that fails for the
  reason the behaviour is missing -- an assertion against a stub, never a
  compile error -- and only then is the code written; a test never seen
  failing may test nothing. A bug's fix starts with the test that
  reproduces it. The test is the interface's first caller, so an awkward
  test is an awkward API. Then the corner cases (empty, one, the
  boundaries, invalid input, a failure partway through), a property
  wherever a round trip exists, and the real server wherever a test can
  run one; a stub stands in only for a third party's service. A
  refactoring adds no test and keeps every one passing.
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
  (`Angstrom.( ... )`, `Float.( ... )`, `Mtime.Span.(30 * s)`). Any other `open` is one the
  repository's rules name, with its reason.
- [ ] **No silenced warnings.** The warning set in `dune` is the linter --
  warning 9 makes adding a record field a compile error at every pattern
  that should handle it -- and a warning that looks wrong is a code shape
  that is wrong.
- [ ] **Ergonomics is a requirement, never a polish.** It is judged where
  the code is used -- the tests, the examples, the README, every caller:
  the common case reads in one obvious line, a caller writes nothing the
  code could have known, a mistake is a compile error or a refusal that
  says what to do, and there is one way to do a thing. A change that
  leaves a caller's code longer, noisier or easier to get wrong is redone,
  however clean its inside. The shapes are the stdlib's: `t` for a
  module's own type and first among its arguments, a function before the
  collection it walks, `create`/`make`, `of_x`/`to_x` and `*_opt`; a label
  wherever two arguments could be swapped, and an optional argument with
  its default, followed by `()`.
- [ ] **An `.mli` per library module**: abstract types, hidden
  constructors, the contract in odoc. It exports what a user needs and
  nothing more, and **a library's user is whoever builds on it, not this
  repository**: an abstraction an application would reach for stays
  exported though only its tests call it, while a helper, a step of the
  implementation or a representation is not exported however convenient.
  In an application, an `.mli` is written for a module other modules could
  break -- a store, the domain's rules -- and left out of a leaf only the
  code above it calls, where a signature only repeats the code.
- [ ] **A library never prints or reads the environment, and exits only
  where its `.mli` says.** An executable reads its environment where it
  starts. A library logs on its own `Logs` sources.
- [ ] **A library runs no event loop of its own.** It takes what it uses --
  `env`, a switch (`~sw`), a clock, a network -- from its caller, and never
  calls `Eio_main.run`. State a module keeps at its top level is filled
  once as it loads and only read after, or is an `Atomic` or behind a
  `Mutex`, since its callers may run on several domains.
- [ ] **A log line stands alone, and a secret has no log level.** A line
  says enough to be read among a thousand others and is never split
  across two. No header value, body, query string, credential or
  statement parameter is logged, at any level.
- [ ] **A meaning is a type.** A state is a variant, never a string, a
  boolean or a pair of booleans one combination of which is impossible; a
  unit or an identifier that travels unnamed -- a column, an element, a
  returned value -- is a type of its own, never a bare `int` or `string`
  whose meaning the caller has to remember. A time is `Ptime.t` or
  `Mtime.Span.t` (*Shared shapes*); a whole number a protocol fixes is
  labelled with its unit at every call (`~retry_after_s`).
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
  function). A name never repeats its module (`Pool.connection`, never
  `Pool.pool_connection`), says `get` only where something is fetched, and
  is as long as its scope is wide. A rename is made only where a caller's
  reader misreads the current name or has to look it up, never because a
  rule can be cited for it; where no natural name comes, the plainer one
  stays, since a name assembled from parts to satisfy a rule
  (`renewals_per_idle`) is worse than none.
- [ ] **A number with a reason is named where nothing beside it already
  says it**, the reason beside it: a field, a label or a comment that
  says its purpose and its unit (`send_timeout = Mtime.Span.(10 * s)`)
  needs nothing more.
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

### Shared shapes

What every Hypha OCaml repository does alike, so that a user of one finds
the next where they expect it.

- **OCaml 5.5 or later, `(lang dune 3.18)`.** Every `dune-project` asks
  for the same, every switch is that OCaml, and CI builds on it with the
  oldest versions the opam files allow. They move together, never one
  repository alone.
- **A library reaches only what it lists.** Every `dune-project` sets
  `(implicit_transitive_deps false)`, so a `dune` file's `libraries` are
  all its code can name, never a library it gets through another. Why: a
  boundary a repository declares -- what a package may link, which driver
  it never names -- is then held by the compiler, not by a reader.
- **A package declares what its code names.** Every package whose library
  a package's code names is in that package's `depends`, `:with-test`
  where only its tests name it, with a lower bound no older than the
  oldest that works. Why: explicit is better than implicit; a library
  reached because another dependency brings it breaks the build the day
  that dependency stops.
- **A `Logs` source is named after its library's public name**
  (`rowtype-postgres`, `spindle.http`), and a part of it after a dot
  (`postgres-eio.pool`), so a user filters a library by the name they
  installed.
- **An error's printer is `error_to_string`**, beside the `error` type it
  prints.
- **An error's tags say what failed, and group what is handled alike.**
  A resource's states sit under the resource (`` `Pool `Busy ``,
  `` `Connection `Closed ``), so a caller handles the whole resource in one
  arm and no two resources share a word; what happened to the work is a
  flat tag with one handling each, never grouped with a case handled
  otherwise; a function's own error that its caller maps at once keeps the
  function's words. Polymorphic tags are one namespace across every
  library, so a tag means one failure wherever it is merged.
- **An instant is a `Ptime.t`.** A point in time is a `Ptime.t` in every
  signature, field and value, never a count of seconds or milliseconds
  since 1970 (`now : Ptime.t`, `expires : Ptime.t`). It is read from a
  clock in the library's clock module alone (below), and turned into its
  written form -- an HTTP date, a `timestamptz`, a JSON string or number --
  only where it crosses a wire. Why: one type for when, the ecosystem's,
  with its arithmetic (`Ptime.add_span`, `Ptime.diff`); an `int` does not
  say whether it counts seconds or milliseconds.
- **A duration is an `Mtime.Span.t`, named for what it bounds.** How long
  the program, or a server it configures, may take or wait is an
  `Mtime.Span.t`, labelled for what it bounds and never for a unit
  (`?timeout`, `?wait`, `~after`), and written `Mtime.Span.(30 * s)`. It
  reaches Eio as it is (`Eio.Time.Timeout.v`, `Eio.Time.Mono.sleep_span`),
  and a format's unit only where it is written, rounded up (Postgres's
  `statement_timeout` in whole milliseconds). Why: a unit that is wrong
  does not compile, and the label is left to say what the wait is for.
- **A wait until an instant is the span from now to it, and zero once it
  has passed.** It is worked out by one function (`until ~now deadline`),
  never by subtracting instants by hand. Why: `Ptime.diff` can be
  negative and a wait cannot, so one place decides what a deadline already
  passed means.
- **A number written into a message for another to read is an `int` in
  the message's unit**, labelled with that unit as the protocol fixes it:
  `~retry_after_s:int` for `Retry-After`, `?max_age_s:int` for
  `Access-Control-Max-Age`. Why: it is a field's value, whole by the
  protocol's definition, not a wait the program counts; a span rounded on
  its way to the field would hide the rounding.

  A time is one of these four in every library and every application,
  with no exception: typed inside, and a bare number only where it
  crosses to an interface that takes nothing else, as a wire's format is
  reached only where it is written.
- **A typed interface is used wherever one exists.** A clock, a sleep or
  a bound on work is reached through the form that takes or gives a
  `Ptime.t` or an `Mtime.Span.t` (`Eio.Time.Timeout.v`,
  `Eio.Time.Mono.sleep_span`, `Ptime_clock.now`, `Mtime_clock.counter`).
  Its bare-number twin is in the `refused` list below, refused in every
  file. Why: a typed form exists, so a bare number there is a unit left
  for the reader to remember.
- **Where none exists, time crosses in the library's clock module.** Two
  calls have no typed form: `Eio.Time.now`, the wall clock as a float, and
  `Unix.sleepf`, the one sleep for code no Eio loop runs (a domain or a
  thread of its own). A library that needs either keeps them in one
  module, `Instant` (`instant.ml`), which takes and gives only `Ptime.t`
  and `Mtime.Span.t` and converts on the spot (`Instant.of_clock`,
  `Instant.sleep`); they are in the `only-in-the-clock-module` list
  below, refused in every other file. Why: the boundary is one place a
  reader can find, typed on both sides, like a wire's codec; a library
  that never needs them has no such module.
- **A `float` labelled with a unit is refused** (`_s`, `_ms`, `_us`,
  `_ns`), in every file: a time is typed.
- **Tests are Alcotest, and a property is QCheck** through
  `qcheck-alcotest`.
- **The refused names are three lists**, below, held in review: every
  file refuses the names in `refused`, calls that can fail without a value
  and time in a bare number; a library's files -- each directory whose
  `dune` declares a `library` -- also refuse the names in
  `refused-in-a-library`, reading the environment, printing and exiting,
  which an executable (a command, a test, an example) does where it starts
  and a library never; and the names in `only-in-the-clock-module` are
  refused in every file but a library's `instant.ml`. A name a
  repository's own rules allow in a place they name -- `invalid_arg` where
  a description is built and can mean nothing -- is allowed there alone. A
  name is read with a leading `Stdlib.` taken off, so `Stdlib.exit` is
  `exit`, and an alias hides nothing: `module L = List` then `L.hd` is
  `List.hd`. A search finds most of them in a change:
  `rg -n -w 'List\.hd|failwith|Unix\.sleepf' src`.

  ```refused
  failwith
  invalid_arg
  Option.get
  Result.get_ok
  Result.get_error
  List.hd
  List.tl
  List.nth
  Obj.magic
  compare
  Stdlib.compare
  Unix.time
  Unix.gettimeofday
  Unix.sleep
  Unix.alarm
  Unix.setitimer
  Unix.getitimer
  Sys.time
  Eio_unix.sleep
  Eio.Time.sleep
  Eio.Time.sleep_until
  Eio.Time.with_timeout
  Eio.Time.with_timeout_exn
  Eio.Time.Timeout.seconds
  Eio.Time.Mono.sleep
  ```

  ```only-in-the-clock-module
  Eio.Time.now
  Unix.sleepf
  ```

  ```refused-in-a-library
  Sys.getenv
  Sys.getenv_opt
  Unix.getenv
  Unix.environment
  exit
  print_string
  print_endline
  print_bytes
  print_char
  print_int
  print_float
  print_newline
  prerr_string
  prerr_endline
  prerr_bytes
  prerr_char
  prerr_int
  prerr_float
  prerr_newline
  stdout
  stderr
  Printf.printf
  Printf.eprintf
  Format.printf
  Format.eprintf
  Format.print_string
  Format.std_formatter
  Format.err_formatter
  ```

## OCaml tools

**What the code means is asked of the compiler, never guessed.** A name's
definition, its references, its type and a module's contents come from the
language server (the `LSP` tool) or, without one, Merlin's command line;
`rg` answers only what is text. Every caller of a changed signature and
every user of an export is found this way, since a shadowed, re-exported
or aliased name defeats a text search.

Nothing is on PATH. Every OCaml tool runs through the repository's local
switch, `opam exec --switch=<root> --` from the repository's root, or
through the Makefile; no `eval`. `make setup` installs Merlin and
`ocaml-lsp-server` with the rest.

**The switch is ignored as `_opam`, never `_opam/`.** A worktree's switch
is a link to the checkout's, which a pattern for a directory does not
match, so `git add -A` there would commit it.

**`ocamllsp` runs as the agent's language server**, from the repository's
own switch. It answers every edit to OCaml source with its type errors,
and gives a name's definition, its references, tests included, its type
and a file's symbols; ask for the symbols before reading a long file
whole. References read the index as the last build left it, so after an
edit rebuild it -- `dune build @check @ocaml-index` -- before asking.

**Without the language server, Merlin's command line answers the same**:
`ocamlmerlin single <query> -filename FILE < FILE`, in JSON, lines from 1
and columns from 0 -- `occurrences -identifier-at LINE:COL -scope
project`, `locate -position LINE:COL`, `type-enclosing -position LINE:COL`,
`outline` and `errors`. Its `occurrences` reads the index as the last
`dune build @ocaml-index` left it.

**Ask for a record field's uses from its definition in the `.ml` or from
a use**, never from its declaration in the `.mli`, which answers with that
declaration alone; a value asked from its `.mli` finds every use.

**A dependency's API is read where it is installed**, from its `.mli`
under `_opam/lib/<package>/` or the server's hover, never from memory: the
version in the switch is the one the code builds against.

**The stdlib is 5.5's, and nothing newer.** A function whose odoc says
`@since` a later version is not used until every `dune-project` asks for
that version.

**A generated file is changed at its source.** An `*.opam` file is written
by dune from `dune-project`, and from an `*.opam.template` beside it for
what dune cannot say, so either of those is edited, never the `.opam`.
Nothing under `_build/` or `_opam/` is edited; a test's new expected
output is taken with `dune promote`.

**A worktree inside the checkout is its own dune root only with an
untracked `dune-workspace`**, holding the `dune-project`'s own `(lang dune
...)` line and kept out of version control. Without one dune takes the
checkout around it as the root and skips the hidden directory the worktree
is in, so the server and Merlin answer from no configuration: every module
unbound, one use of every name. For a single command, `DUNE_ROOT` set to
the worktree does the same.

`dune describe` lists every library, executable and module, so nothing is
missed when the whole project is read.

**Search text with `rg`, always with a path**, never `grep -r` or `find`:
with no path `rg` reads standard input, which an agent's shell never
closes, and `_build/` and `_opam/` are gitignored, so `rg` skips them
where `find . -name '*.ml'` returns every copy of the source under
`_build/` and every package under `_opam/`.

`opam list --installed` says what the switch holds; `opam list
--required-by --recursive` resolves against what is available, not what is
installed.
