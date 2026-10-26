# Broadcast subscriptions: released by their scope, forwarded in one call

**Status: Accepted** — accepted by the owner on 2026-10-26 ("just do the work"); the functions have landed, the benchmark waits for 0.13.0.
Date: 2026-10-26

## The problem

A route that broadcasts writes the same ten lines of glue, and the glue
the guide teaches leaks subscriptions and is slow at scale. Each fault is
measured below, on Spindle 0.11.0, macOS.

- **A cancelled subscriber's release can give up, so a subscription
  outlives its client.** A route releases with
  `Fun.protect ~finally:(fun () -> Broadcast.unsubscribe hub sub)`. A
  release often runs in a fiber that is already cancelled: the WebSocket
  guide's chat runs its two loops under `Eio.Fiber.first`, which cancels the
  writing one when the client leaves, and a stopping server cancels every
  handler still running when its drain ends. `unsubscribe` takes the hub's `Eio.Mutex`, and Eio raises
  `Cancelled` at once for a cancelled fiber that has to wait for a lock. So
  whenever another domain is publishing at that moment, the release raises
  out of `finally` as `Fun.Finally_raised` and the subscription stays.
  2,000 subscribers cancelled while a second domain published: **37–41 left
  behind** in each of five runs, and as many `Finally_raised`.
- **What is left behind is kept in memory.** A leaked subscription holds its
  record, its tag, its queue and up to `depth` events, and keeps its topic in
  `topics`. `subscribers` lists a client that has gone, so presence built on
  it is wrong. A busy topic frees it after `depth + 1` more events, when
  `publish` drops it as a slow subscriber, which the same probe confirmed. A
  quiet topic never does: a server whose rooms come and go keeps every dead
  room's leaked subscriptions until it restarts.
- **A release can also be forgotten.** `subscribe` hands out a subscription
  and trusts the caller to give it back. Spindle's own stop test
  (`test_a_stop_lets_answers_finish`) subscribes and never unsubscribes.
- **Ending a quiet stream costs a race on every event.**
  `Broadcast.next ~until:gone` waits in `Eio.Fiber.first`, the queue against
  `Spindle.client_gone`, so every event to every subscriber sets up and
  cancels two fibers. One domain, 5,000 subscribers, CPU time:

  | | 200 events | 1,000 events |
  |---|--:|--:|
  | `next` | 0.57 s | 2.8–4.2 s |
  | `next ~until` | 1.75–1.86 s | 8.7–9.0 s |
  | one watcher a subscription, the design below | 0.66–0.76 s | 3.2–3.3 s |

  Through a server, the benchmarks repository's fan-out on Spindle 0.6.0
  (2026-10-16) found the same: 0.61 cores against 0.33 at 5,000
  subscribers, and at 10,000 the server fell behind while subscriptions
  opened and never caught up.
- **Every broadcasting route writes the same loop.** Subscribe, protect,
  unsubscribe, then a `match` over `next` and `send` until `None`: the SSE
  guide, the WebSocket guide, both route tests and the benchmark all spell it
  out. Nothing in it is the application's.

Asked for by the owner. On 2026-10-16, from the benchmark: "I care about
API ergonomics". On 2026-10-26: "api ergonomics is never a trade-off and
must be consistent across the project"; a breaking change "must be
justified"; the solution must be "simple by design because if it's complex
- it's wrong"; and Spindle "is a general-purpose framework for everyone", so
a function is judged by what any application needs, not by today's callers.

## Scope

In it, in `spindle` alone:

- `Spindle.Broadcast`: `subscribe` takes the work that uses the
  subscription and releases it however that work ends; `forward`, new; every
  use of the hub's lock made safe from cancellation.
- The SSE and WebSocket guides' broadcasting sections, the `.mli` texts that
  point at `next ~until`, the tests, `CHANGES.md`.

Not in it:

- `create`, `unsubscribe`, `next`, `publish`, `close`, `topics` and
  `subscribers`, which keep their signatures and behaviour.
- Broadcasting across processes, resuming from `Last-Event-ID`, topics by
  pattern, anything in Eio.

Afterwards, elsewhere: the benchmarks repository's route moves to the
scoped `subscribe` when it takes 0.13.0, and the fan-out is run again with
`forward ~until:gone`.

## User scenarios

1. **Forward a topic.** A route forwards a topic to its stream in one
   expression. *Accepted when* every event published arrives in order, and
   once the stream ends `subscribers` no longer lists it.
2. **A cancelled subscriber is released.** *Accepted when* 2,000
   subscribers, each cancelled while another domain publishes, leave
   `subscribers` empty and raise nothing.
3. **State first, then changes.** A route sends the current state, then
   every change. *Accepted when* an event published between subscribing and
   sending the state still arrives.
4. **Each subscriber its own.** A route forwards only what its subscriber
   may see, or turns each event into another. *Accepted when* it is written
   with `forward` and a `send` of its own, nothing else.
5. **A client leaves a quiet topic.** *Accepted when* `forward ~until`
   returns `Ok ()` as soon as `until` resolves, with no event published, and
   `subscribers` stops listing it at that moment.
6. **A send already running is never cancelled.** *Accepted when* a `send`
   running as `until` resolves finishes, and its answer is what `forward`
   answers.
7. **A slow subscriber, or one ended from outside.** *Accepted when*
   `forward` returns `Ok ()` once the hub drops the subscriber as slow, once
   another fiber calls `unsubscribe` on it, and once the hub is closed.
8. **Ten thousand subscribers.** *Accepted when*, in the benchmarks
   repository, forwarding with `~until` costs an event what plain `next`
   costs, within its run-to-run range, and 10,000 subscribers on one domain
   are each sent every event.

## Requirements

- **FR-1.** A subscription is released however the work that uses it
  ends: it returns, raises, or is cancelled.
- **FR-2.** No hub operation fails or leaves its work half done because its
  fiber is cancelled.
- **FR-3.** A route forwards a subscription to its stream in one call,
  which answers the first `Error` its `send` answers, and `Ok ()` once the
  subscriber is dropped, unsubscribed or closed, or `until` resolves.
- **FR-4.** `until` resolving never cancels `send`, nor anything `send` runs.
- **FR-5.** An event forwarded with `until` costs what one forwarded without
  it costs.
- **FR-6.** Nothing new raises.
- **FR-7.** `create`, `unsubscribe`, `next`, `publish`, `close`, `topics` and
  `subscribers` behave as they do today.

## Design

### The interface

```ocaml
val subscribe :
  ('tag, 'event) t -> topic:string -> 'tag ->
  (('tag, 'event) subscription -> 'a) -> 'a
(** Subscribes, runs [f] with the subscription, and unsubscribes however [f]
    ends -- returned, raised or cancelled. *)

val forward :
  ?until:unit Eio.Promise.t -> ('tag, 'event) subscription ->
  ('event -> (unit, 'e) result) -> (unit, 'e) result
(** Hands every event to [send], in order, until the subscriber is dropped,
    unsubscribed or closed -- [Ok ()] -- or [send] answers an error, which it
    answers in turn. [until] resolving unsubscribes it as {!unsubscribe}
    does, so [subscribers] stops listing it at once, and a [send] already
    running finishes: nothing is cancelled. *)
```

The rest of the module is as it is. The hub's operations take the hub
(`publish`, `unsubscribe`, `close`, `topics`, `subscribers`); a
subscription's operations take the subscription (`next`, `forward`).

### Before and after

The SSE guide's route today:

```ocaml
(let+ room = Spindle.param room and+ gone = Spindle.client_gone in
 Ok
   (fun send ->
     let sub = Spindle.Broadcast.subscribe hub ~topic:room () in
     Fun.protect
       ~finally:(fun () -> Spindle.Broadcast.unsubscribe hub sub)
       (fun () ->
         let rec loop () =
           match Spindle.Broadcast.next ~until:gone sub with
           | Some event ->
               let* () = send event in
               loop ()
           | None -> Ok ()
         in
         loop ())))
```

With this:

```ocaml
(let+ room = Spindle.param room and+ gone = Spindle.client_gone in
 Ok
   (fun send ->
     Spindle.Broadcast.subscribe hub ~topic:room () (fun sub ->
         Spindle.Broadcast.forward ~until:gone sub send)))
```

State first, subscribed before it is read, so nothing published in between
is missed:

```ocaml
Ok
  (fun send ->
    Spindle.Broadcast.subscribe hub ~topic:room () (fun sub ->
        let* () = send (Spindle.Event.make state (Room.current room)) in
        Spindle.Broadcast.forward ~until:gone sub send))
```

Each subscriber its own:

```ocaml
Ok
  (fun send ->
    Spindle.Broadcast.subscribe orders ~topic:"orders" user (fun sub ->
        Spindle.Broadcast.forward ~until:gone sub (fun order ->
            if Order.visible_to user order then send order else Ok ())))
```

The WebSocket guide's chat, whose `Fiber.first` ends the forwarding when
the client leaves:

```ocaml
let chat ws =
  Spindle.Broadcast.subscribe hub ~topic:"lobby" () @@ fun sub ->
  let rec listen () =
    let* said = Ws.receive ws in
    Spindle.Broadcast.publish hub ~topic:"lobby"
      (Ws.encode (Ws.server protocol) said);
    listen ()
  in
  Eio.Fiber.first listen (fun () ->
      Spindle.Broadcast.forward sub (Ws.send_encoded ws))
```

### The model

Three changes in `core/broadcast.ml`, each closing one fault:

- **The lock is never given up to cancellation.** `locked` takes the hub's
  mutex inside `Eio.Cancel.protect`. That is safe because the lock is held
  only to edit a list and add to queues that never block, never across a
  wait, so a protected wait for it is short and bounded. It covers every
  operation, not only `unsubscribe`: a cancelled `subscribe` or `publish`
  finishes its edit or never starts it. This is what makes a release unable
  to fail (FR-2); in the probe it took the leaks from 37–41 to 0.
- **`subscribe` owns the release.** It runs `f` and unsubscribes on every
  way out, re-raising what `f` raised with its backtrace. Because the release
  cannot fail, nothing is wrapped in `Fun.Finally_raised`, and a release
  cannot be forgotten, since no subscription exists outside a call of `f`
  (FR-1). Ending one early, or from another fiber, is still `unsubscribe`,
  and a release after that does nothing, since a subscription is dropped
  once.
- **`forward` watches `until` once, not once an event.** Without `until`
  it takes from the queue as `next` does. With it, it opens a switch and
  forks one daemon fiber that waits for `until` and then unsubscribes the
  subscription, by the path a slow subscriber is dropped by: out of its
  topic, a `None` into the slot the queue keeps for it. The loop reads that
  `None` at its next wait and answers `Ok ()`. The watcher cancels nothing
  (FR-4); when `forward` returns, its switch ends the watcher. One fiber a
  subscription, measured at the cost of plain `next` (FR-5). An `until`
  already resolved answers `Ok ()` without taking an event. An event
  published as `until` resolves may be sent or not, as `next ~until` says of
  one today.

Unsubscribing needs the hub, so a subscription keeps the hub it was made
from, in a field nothing outside `Broadcast` sees.

`next ?until` stays as it is: it is the primitive a reader that is not a
loop needs, and it is correct. Its documentation says it races once a wait,
and sends a loop to `forward`.

### Breaking, and why

One change breaks: `subscribe` takes `f`. Its reason is the leak that a
forgotten release is, which Spindle's own test shows can be written, and the
consistency of borrowing: `Spindle_postgres.Pool.use` and
`Spindle_sqlite.Pool.use` lend a connection only for a function, never as a
value to give back. Before 1.0 a breaking change bumps the minor version, so
this ships as 0.13.0. A caller's rewrite is mechanical and shorter: its
`Fun.protect` and `unsubscribe` go.

### Files

- `core/broadcast.ml`, `core/broadcast.mli`: `locked` under
  `Cancel.protect`, `subscribe` scoped, `forward`, the subscription's hub;
  `next`'s documentation pointing at `forward`.
- `core/spindle.mli` (`client_gone`'s example), `core/request.mli` and
  `core/event.mli`: their mention of `next ~until` as `forward ~until`.
- `docs/src/content/docs/guide/sse.mdx`: *Broadcasting to many clients*
  with `forward`, and the state-first form.
- `docs/src/content/docs/guide/websockets.mdx`: *Broadcasting to many
  sockets* with `forward`.
- `test/test_spindle.ml`, `test/test_websocket.ml`: the rows in
  *Verification*, and every existing use moved to the scoped `subscribe`.
- `AGENTS.md`: the rule below. `CHANGES.md`: its entry.

### Alternatives rejected

- **Only `Eio.Cancel.protect`, keeping `subscribe` as it is.** It fixes the
  cancelled release and no break is needed, but a forgotten release still
  compiles, and every route keeps writing its `Fun.protect`.
- **A scoped function beside today's `subscribe`** (the first draft's
  `with_subscription`). Nothing breaks, but there are two ways to subscribe
  and one of them leaks. And in Spindle `with_` makes a copy with something
  changed (`Response.with_header`); a scope is a verb taking a function, as
  `Pool.use` and `Pool.transaction` are.
- **`subscribe ~sw`**, released when a switch ends, as Eio's resources are.
  Every route would open a switch for one subscription, a heavier call than
  the function it replaces.
- **Removing `unsubscribe`.** The scope releases, but ending a subscription
  from outside its reader -- a ban, a sign-out, a revoked permission -- is
  basic pub/sub, and nothing else does it.
- **Removing `next`, or its `?until`.** Every loop is better as `forward`,
  but a reader that takes one event and does something else needs the
  primitive, and `next ~until` is correct, only slower. Breaking either buys
  nothing a user asked for.
- **A `stream` shortcut** for `subscribe` and `forward` together (the first
  draft's). `subscribe hub ~topic tag (fun sub -> forward ~until sub send)`
  is already one expression; a third function would be a second spelling of
  it.
- **One `Fiber.first` around the whole loop**, the forwarding against
  `until`. One race a subscription, but its cancellation lands in whatever
  is running, `send` and the route's wrapper around it: a filter that reads
  the database, cancelled mid-query. That breaks *a socket's failures are
  values*.
- **Making `next ~until` cheap in place.** Watching a promise once a
  subscription rather than once a wait needs a scope that outlives the
  waits, which `next` does not have and `forward` is.
- **Lock-free topic lists**, so a release never waits at all. Two
  publishers could then both pass the capacity check and spend the slot kept
  for a dropped subscriber's `None`, which is what the lock exists to stop.
- **Marking a released subscription dead and pruning it at the next
  publish**, so a release takes no lock. A quiet topic never publishes, so it
  would keep exactly the leak this closes.

## Rules it adds

- **A release cannot be cancelled.** Whatever gives a resource back --
  a subscription to its hub -- takes its lock under `Eio.Cancel.protect`,
  since a release often runs in a fiber already cancelled, where waiting for
  a lock another domain holds raises and the resource is never given back.
  Test: `test_spindle` cancels 2,000 subscribers while another domain
  publishes, and finds none left.

## Stages

- [x] **The functions.** `locked` under `Cancel.protect`, the scoped
  `subscribe` and `forward`, with the leak row first, seen failing on
  today's code; every caller in the tests moved; the `.mli` texts that point
  at `next ~until`; the guides; the rule in `AGENTS.md`; `CHANGES.md`.
- [ ] **The benchmark**, in the benchmarks repository once 0.13.0 is
  released: its route as `subscribe` and `forward ~until:gone`, and the
  fan-out run again.

## Verification

`make test` and `make lint` pass. `test_spindle`, on one domain and on
four, has a row for each scenario but the last:

- **The leak (2).** 2,000 subscribers, each in a fiber cancelled while
  another domain publishes in a loop, then `subscribers` empty and no
  exception. It is seen failing on today's code before the fix (37–41 left
  in the probe). With the fix it cannot fail, since a protected wait for the
  lock is never cancelled, so its green verdict does not depend on the
  machine; an existing row already floods a hub from two domains.
- **Order (1)**: events arrive in the order published, and the subscription
  is gone once `subscribe`'s `f` returns, raises, or is cancelled.
- **State first (3)**: an event published between subscribing and the first
  `send` arrives.
- **Quiet topic (5)**: `forward ~until` on a topic nothing is published to
  returns once `until` resolves, on `In_memory`'s virtual time, with
  `subscribers` empty from then on.
- **Send never cancelled (6)**: a `send` waiting on a promise of the test's
  when `until` resolves still completes, and its `Error` is `forward`'s
  answer.
- **Ends (7)**: a slow subscriber dropped, another fiber's `unsubscribe`, and
  `close` each end `forward` with `Ok ()`.

Scenario 8 is the second stage, measured by hand in the benchmarks
repository, since a test's verdict never turns on how fast the machine is.

## Where the facts go

| A fact | Its owner |
|---|---|
| `subscribe`'s scope, `forward`'s contract, why `until` unsubscribes rather than cancels | `core/broadcast.mli` |
| Why the lock is protected, beside `locked` | one clause in `core/broadcast.ml` |
| How a route broadcasts, the state-first form, the chat | `docs/src/content/docs/guide/sse.mdx`, `guide/websockets.mdx` |
| *A release cannot be cancelled* | *Rules that must hold* in `AGENTS.md` |
| What changed for a user | `CHANGES.md`, under `## Unreleased` |
| The measurements, and the alternatives | the commit message |
