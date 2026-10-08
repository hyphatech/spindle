# Multicore and shared state

Spindle serves on every core: by default it runs
`Domain.recommended_domain_count ()` domains, and your handlers run on all of
them in parallel. So anything a handler touches must be one of:

- **Immutable after startup** -- the app, its routes, whatever you loaded
  before the server started.
- **Safe from any domain** -- an `Atomic` for a count, an `Eio.Stream` or
  `Eio.Promise` to hand values across, an `Eio.Mutex` around a table. Hold a
  mutex only around the table itself, never across a database call or a write
  to a client: every other domain waits behind it.

If your application's state is not safe from several domains, serve it on
one, with `~domains:1`. Fibers then switch only at an effect, so code between
two effects needs no lock.

## Shared state: a lock, or one domain

Each visit to `/pages/<name>` counts one, in a `Hashtbl` behind an
`Eio.Mutex`; with `--one-domain` it runs on one domain with no lock:

```ocaml
--8<-- "multidomain.ml"
```

```sh
dune exec examples/multidomain.exe
```

```sh
curl localhost:8080/pages/home
```

```text
home: visit number 1
```

```sh
curl localhost:8080/pages/home
```

```text
home: visit number 2
```

A `Hashtbl` with neither a lock nor one domain loses writes, misses entries
that are there, and can raise from inside a resize -- and none of it shows on
a laptop's first try.

## Domains and background work

- A connection stays on the domain that accepted it, for its whole life.
- Work forked from a handler -- `Background`, `Alarm` -- runs on that
  handler's domain, on its switch, `Spindle.Local.switch ()`. Outside a
  server (startup code, a test), `Spindle.Local.within ~sw f` sets one.
- `Spindle.blocking f` runs `f` on a system thread, for a library that blocks.
  Inside `f`, perform no Eio effect and touch nothing a fiber owns.
- Spindle raises each domain's minor heap to a million words (8 MB) so that
  requests in flight are collected young. It never lowers it:
  `OCAMLRUNPARAM=s=4M` asks for four million words.
