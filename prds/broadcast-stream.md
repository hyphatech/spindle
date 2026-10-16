# Broadcasting to an event stream in one expression

**Status: Draft** — the shape below is proposed; nothing in it is accepted,
nothing is built.
Date: 2026-10-16

## The problem

An events route that broadcasts is the same twelve lines every time, and
the way the guide writes them costs too much to serve many subscribers.

- **Every broadcasting route writes its own loop.** The guide's
  *Broadcasting to many clients* subscribes, unsubscribes in a
  `Fun.protect`, and loops over `Broadcast.next` and `send`. Nothing in the
  route is the application's: it is the glue between a subscription and a
  stream, and each route spells it again. NestJS answers the same with one
  line, `@Sse() events() { return ticks$; }`, because RxJS does the
  fan-out -- with no bound on a slow subscriber, which Spindle rightly
  keeps.
- **The guide's way of ending a quiet stream is a race per event.**
  `Broadcast.next ~until:gone` waits in `Eio.Fiber.first`, the queue
  against `Spindle.client_gone`, so every event to every subscriber sets
  up and cancels two fibers. Measured with the benchmarks repository's
  fan-out client on Spindle 0.6.0, macOS, one domain, on 2026-10-16, the
  route differing only by `~until`:

  | | `next` | `next ~until` |
  |---|--:|--:|
  | 5,000 subscribers: cores while delivering | 0.33 | 0.61 |
  | 5,000 subscribers: delivery p99 | 38 ms | 67 ms |
  | 10,000 subscribers | every event delivered | 9,360 subscribed in 65 s, 5 events published |

  At 10,000 the race costs more than a core, so the server falls behind
  while subscriptions open and never catches up. Every route written as
  the guide writes it has this cliff.

Asked for by the owner on 2026-10-16, from the benchmark: "I care about
API ergonomics", "I need flexible ergonomics here as well, aligned with
in-house rules".

## Scope

- **Covers**: `Spindle.Broadcast` -- three functions beside the ones it
  has; the guide's broadcasting section and `Spindle.client_gone`'s
  example rewritten with them; their tests; a line in CHANGES.md.
- **Does not cover**: changing `subscribe`, `next` or `unsubscribe`, which
  keep their behaviour; broadcasting across processes; resuming from
  `Last-Event-ID`, which stays the route's; topics by pattern; anything
  in Eio.
- **Afterwards, elsewhere**: the benchmarks repository's Spindle route
  uses the one expression, once a release carries it.

## User scenarios

1. **Forward a topic.** A route forwards a topic to its stream in one
   expression. Accepted when the expression is the route's producer as it
   stands, every event published arrives in order, and the subscription
   is gone from `Broadcast.subscribers` once the stream ends.
2. **State first, then changes.** A route sends the current state, then
   every change. Accepted when an event published between the subscriber
   joining and the state being sent still arrives.
3. **Each subscriber sees its own.** A route forwards only what its
   subscriber may see, or turns each event into another. Accepted when it
   is written with the same function and a `send` of its own, nothing
   else.
4. **A client leaves a quiet topic.** Accepted when the producer ends at
   the keep-alive that finds the client gone, without waiting for an
   event, and the subscription is released.
5. **A slow subscriber is dropped.** Accepted when the producer ends with
   `Ok ()`, as `next`'s `None` ends one today.
6. **A client goes mid-send.** Accepted when a `send` already running --
   the route's own, wrapped round the framework's -- finishes, is never
   cancelled, and its `Error Gone` is what the producer answers.
7. **Ten thousand subscribers.** Accepted when forwarding with `~until`
   costs, an event, what forwarding without it costs, within the
   benchmark's run-to-run range, and 10,000 subscribers on one domain are
   every one sent every event.

## Requirements

- **FR-1** A route forwards a topic to its stream in one expression,
  which is the route's producer.
- **FR-2** A subscription made by the new functions is released however
  its use ends: returned, an `Error`, a raise, a cancellation.
- **FR-3** Forwarding answers the first `Error` `send` answers, and `Ok ()`
  once the subscriber is dropped or unsubscribed, or `until` resolves.
- **FR-4** `until` resolving never cancels `send`, nor anything `send`
  runs.
- **FR-5** An event forwarded with `until` costs what one forwarded
  without it costs: no fiber and no race an event.
- **FR-6** Nothing new raises.
- **FR-7** `subscribe`, `next` and `unsubscribe` behave as they do today.

## Design

### The interface

```ocaml
val with_subscription :
  ('tag, 'event) t -> topic:string -> 'tag ->
  (('tag, 'event) subscription -> 'a) -> 'a
(** Subscribes, runs [f], and unsubscribes however [f] ends. *)

val forward :
  ?until:unit Eio.Promise.t -> ('tag, 'event) subscription ->
  ('event -> (unit, 'e) result) -> (unit, 'e) result
(** Hands every event to [send] until the subscriber is dropped or
    unsubscribed, or [until] resolves -- [Ok ()] -- or [send] answers an
    error, which it answers in turn. [until] resolving drops the
    subscriber as a slow one is dropped: a [send] already running
    finishes, and nothing is cancelled. *)

val stream :
  ?until:unit Eio.Promise.t -> ('tag, 'event) t -> topic:string -> 'tag ->
  ('event -> (unit, 'e) result) -> (unit, 'e) result
(** {!with_subscription} and {!forward}: an events route's producer. *)
```

`stream` given all but `send` is `'s Event.stream` when the hub carries
`'s Event.t`, and a `Response.events` producer when it carries strings,
since `'event` is whatever the hub holds.

### Before and after

The guide's route today:

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
 Ok (Spindle.Broadcast.stream ~until:gone hub ~topic:room ()))
```

State first, subscribed before it is sent, so nothing published between is
missed:

```ocaml
Ok (fun send ->
  Spindle.Broadcast.with_subscription hub ~topic:room () (fun sub ->
    let* () = send (Spindle.Event.make state (Room.current room)) in
    Spindle.Broadcast.forward ~until:gone sub send))
```

Each subscriber its own, by a `send` of the route's:

```ocaml
Ok (fun send ->
  Spindle.Broadcast.stream ~until:gone orders ~topic:"orders" user
    (fun order -> if Order.visible_to user order then send order else Ok ()))
```

### The model

`forward` takes from the subscription's queue as `next` without `until`
does. With `until`, it runs one fiber of its own, in a switch it opens and
closes, that waits for `until` and then drops the subscription by the
path a slow subscriber is dropped by: out of its topic, a `None` into the
slot the queue keeps for it. The loop reads that `None` at its next wait
and answers `Ok ()`. The fiber is one a subscription, not one an event,
and it cancels nothing; when `forward` returns, its switch ends the
fiber.

Dropping needs the hub, so a subscription carries the hub it was made
from, a field nothing outside `Broadcast` sees. `until` already resolved
answers `Ok ()` without taking an event. An event published as `until`
resolves may be sent or not, as `next ~until` says of one today.

### Files

- `core/broadcast.ml`, `core/broadcast.mli`: the three functions, the
  subscription's hub; `next`'s documentation names `forward` for a loop
  over it.
- `core/spindle.mli`: `client_gone`'s example written with `stream`.
- `docs/guide/streams.md`: *Broadcasting to many clients* with `stream`,
  and the state-first form.
- `test/test_spindle.ml`: the rows in *Verification*.
- `CHANGES.md`: its line.

### Alternatives rejected

- **One `Fiber.first` round the whole loop**, the forwarding against
  `until`. One race a subscription, as wanted, but its cancellation lands
  in whatever runs, `send` and the route's wrapper round it: a filter
  that reads the database, cancelled mid-query. That breaks *a socket's
  failures are values*: nothing in the framework cancels a handler whose
  peer has gone.
- **Making `next ~until` cheap in place.** A wait that ends on a promise
  needs something watching the promise. Watching it once a subscription
  rather than once a wait needs a scope that outlives the waits, which
  `next` does not have and `forward` is.
- **`subscribe ?until`**, the subscription ending itself. The watching
  fiber needs a switch, and `Broadcast` has none: the caller would hand
  one in, a heavier call than the loop it replaces.
- **`stream` alone**, with `?first` for the state sent before the
  changes. One function, but every new need -- several states, a state
  read after subscribing, a per-subscriber filter -- is another argument.
  `with_subscription` and `forward` compose for all of them, and `stream`
  is the one case written for you.
- **A combinator in `Response`.** It would bind `Response` to
  `Broadcast`, and a hub carries any event, not only an `Event.t`.

## Stages

- [ ] **The functions.** `with_subscription`, `forward` and `stream` in
  `Broadcast`, with their tests.
- [ ] **The documents.** The guide, `client_gone`'s example, `next`'s
  pointer to `forward`, CHANGES.md.
- [ ] **The benchmark.** Once released, the benchmarks repository's
  Spindle route as `Broadcast.stream ~until:gone`, and its fan-out run
  again.

## Verification

- `test_spindle`, on one domain and on four:
  - events arrive in the order published;
  - a quiet topic's producer ends when `until` resolves, its subscription
    released;
  - a dropped slow subscriber ends the producer with `Ok ()`;
  - `send`'s `Error` is the producer's answer;
  - the subscription is released when the producer returns, answers an
    error, raises, or is cancelled;
  - a `send` running when `until` resolves finishes and is not
    cancelled;
  - with `with_subscription`, an event published between subscribing and
    the first `send` arrives.
- The benchmarks repository, `--scenarios fanout` with the route as
  `stream ~until:gone`: cores while delivering at 5,000 subscribers within
  the run-to-run range of plain `next` (0.33 on the machine above), and
  10,000 subscribers each sent every event.

## Open

- **The names.** `stream` and `forward`, or others; `with_subscription`
  is named as Spindle's other scopes are, `with_span` and
  `with_request_id`. Blocks the first stage.
- **`next ~until` once `forward` exists.** Kept and pointed to `forward`,
  as proposed; or documented as the per-wait form it is. Blocks the
  documents.
- **The version.** Additions only, so 0.6.1 under *Releases*; 0.7.0 if the
  owner wants it marked. Blocks the release, nothing before it.

## Where the facts go

- The three functions' contract, and why `until` drops rather than
  cancels: `core/broadcast.mli`, the reason in one clause.
- How a route broadcasts, and the state-first form: the guide,
  `docs/guide/streams.md`.
- What changed for users: CHANGES.md.
- Why the watcher and not the race: one clause in `core/broadcast.ml`
  beside the code, and the commit message.
