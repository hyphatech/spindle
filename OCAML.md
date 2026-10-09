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
4. **Comments say why, never what**, in a sentence or two: the RFC or
   protocol section, a rule the code must keep, a constraint that is not
   visible, the measured reason for a number. Never history; that is the
   commits'. A comment that explains what the code does means the code is
   rewritten, and one the names already say is deleted.

### OCaml checklist

A change is done when every box holds:

- [ ] The checks under *Commands* in `AGENTS.md` pass.
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
