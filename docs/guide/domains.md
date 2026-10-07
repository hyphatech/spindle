# Domains, and what a handler may touch

A Spindle server runs on **every domain the machine recommends**
(`Domain.recommended_domain_count ()`), unless told a number. Spindle starts
the domains itself, and each has a switch for as long as it serves, its own
deadline sweep, and an accept loop on every address; a connection lives on
the domain that accepted it, and stays there, since Eio cannot move one --
long-lived streams that happen to pile up on one domain stay on it, and a
shared listening socket balances only what is accepted next. So a handler
runs **beside handlers on other
domains**, in parallel, and everything it touches is one of two things:

- **Immutable after startup** -- the app, its routes, whatever was loaded
  before the server started. Made before the domains, read from any.
- **Synchronised** -- a count an `Atomic`, a value handed across a
  `Stream` or a `Promise`, a table behind an `Eio.Mutex` held across no
  effect but its own, since what waits behind it is every other domain.

What the framework keeps is the second kind: the server's counts, the
pool's queue and flag, `Broadcast`'s subscribers, the buffer each domain
gathers its log lines in, and a request id from a random state per domain.
The lines are written by a domain of the log's own, so no domain that
serves waits on stderr.

**Each domain's minor heap holds what its requests keep alive.** A request
holds its state across every read and write, and one still in flight at a
minor collection is promoted for the major collector to pay for. OCaml's
default, 256k words, is about what 256 connections keep in flight, so
Spindle raises every domain it serves on to a million words (8 MB) --
every one, since a domain starts with the default whatever another was
given -- and lowers none: `OCAMLRUNPARAM=s=4M` gives each four.

**A fiber is forked onto its own domain's switch**, because Eio refuses a
fork onto another domain's. `Spindle.Local.switch ()` is that switch on
every domain the server runs, and `Spindle.Local.within ~sw f` binds one for
code outside a server -- startup, a test. `Background`, `Alarm` and the
client's watch on a kept connection all fork onto it, so work runs on the
domain that caused it, with no message and no domain all of it funnels
through.

An application whose own state is not safe from several domains says so
with `~domains:1`, and is served exactly as a one-domain server always was.
Code inside `Spindle.blocking` is on another thread: it reads and returns
values, and never touches the application's state.

## A table, both ways

A table written by every request, behind an `Eio.Mutex`, and on one
domain with no lock -- and what a `Hashtbl` with neither does:

```ocaml
--8<-- "multidomain.ml"
```
