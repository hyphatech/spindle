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
(* A table every request writes: the visits to each page.

   A request runs on any of the server's domains, beside the others, so a
   table they all write is behind a lock -- an [Eio.Mutex], which parks the
   fiber waiting for it rather than its whole domain, held across nothing
   but the table, never across a write to a client or a call to a database.

   A [Hashtbl] with neither a lock nor one domain is not a crash in OCaml 5
   but it is no table either: two domains adding at once lose one of the
   writes, a lookup on one domain sees the other's resize half done and
   finds nothing where something is, and a resize that meets another raises
   from inside the table. None of it shows on a laptop's first try.

   A server that must not lock runs on one domain, [~domains:1], where a
   fiber gives way only at an effect and a table touched between two needs
   nothing: [--one-domain] below. The middleware example keeps a single number,
   which is an [Atomic]; a table is not a number.

     dune exec examples/multidomain.exe
     curl localhost:8080/pages/home
     dune exec examples/multidomain.exe -- --one-domain *)

open Spindle.Syntax

let visits : (string, int) Hashtbl.t = Hashtbl.create 16
let lock = Eio.Mutex.create ()

let visit page =
  let n = 1 + Option.value (Hashtbl.find_opt visits page) ~default:0 in
  Hashtbl.replace visits page n;
  n

let page_name = Spindle.Path.string "page"
let path = Spindle.Path.(s "pages" / page_name)

let locked =
  Spindle.get path Spindle.Returns.text
    (let+ page = Spindle.param page_name in
     let n = Eio.Mutex.use_rw ~protect:false lock (fun () -> visit page) in
     Ok (Printf.sprintf "%s: visit number %d\n" page n))

let unlocked =
  Spindle.get path Spindle.Returns.text
    (let+ page = Spindle.param page_name in
     Ok (Printf.sprintf "%s: visit number %d\n" page (visit page)))

let () =
  Spindle.Log.setup ();
  let one_domain = Array.exists (String.equal "--one-domain") Sys.argv in
  Eio_main.run @@ fun env ->
  if one_domain then Spindle.serve env ~domains:1 [ unlocked ]
  else Spindle.serve env [ locked ]
```

```sh
dune exec examples/multidomain.exe
```

or, on one domain with no lock:

```console
$ dune exec examples/multidomain.exe -- --one-domain

$ curl localhost:8080/pages/home
home: visit number 1

$ curl localhost:8080/pages/home
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
