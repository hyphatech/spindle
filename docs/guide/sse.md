# Server-Sent Events (SSE)

A Server-Sent Events stream sends events until it is done. `Broadcast`
sends one event to everyone listening.

## A resumable event stream

`GET /count` sends a number a second, and a client that reconnects carries
on where it left off:

```ocaml
--8<-- "sse.ml"
```

```console
$ curl -N localhost:8080/count
event: count
id: 1
data: 1

event: count
id: 2
data: 2
...

$ curl -N -H 'Last-Event-ID: 41' localhost:8080/count
event: count
id: 42
data: 42
...
```

- **The producer** is the function the route answers with, `fun send ->
  ...` (here `count_from ~mono_clock n`, waiting on the clock the route
  reads as a [resource](../tutorial/dependencies.md#resources)). It runs after the response's head
  is sent, and the stream ends when it returns.
- **Declare each kind of event**: `Event.json "count" Wiretype.int`, or
  `Event.text "token"` for plain text. `type counting` is declared and never
  defined: it is a label every kind of this stream carries, so the compiler
  refuses an event declared for another stream.
- **`send` answers `Error Gone` once the client has gone**, so a loop
  written with `let*` ends there. It also answers `Error Gone` after the
  producer has returned, so a fiber left holding `send` writes nothing.
- **Resuming:** give each event an id (`Event.make ~id`). A browser sends
  the last one back as `Last-Event-ID` when it reconnects.
  `Event.retry ~ms` tells the browser how long to wait before it reconnects.
- A quiet stream gets a `: keep-alive` comment every 15 seconds
  (`Returns.events ~keep_alive`). `Event.comment` sends one of your own.
- The OpenAPI document describes each kind of event the route declares.

## Broadcasting to many clients

`Broadcast` sends one event to every subscriber of a topic, within one
process:

```ocaml
open Spindle.Syntax

type room

let count : (int, room) Spindle.Event.kind =
  Spindle.Event.json "count" Wiretype.int

let hub : (unit, room Spindle.Event.t) Spindle.Broadcast.t =
  Spindle.Broadcast.create ~depth:16 ()

let room = Spindle.Path.str "room"

let events =
  Spindle.get
    Spindle.Path.(s "rooms" / room / s "events")
    (Spindle.Returns.events Spindle.Event.[ declare count ])
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
               | None -> Ok () (* dropped as slow, unsubscribed, or gone *)
             in
             loop ())))

(* Anywhere else: make the event once, and everybody gets it. *)
let () =
  Spindle.Broadcast.publish hub ~topic:"lobby" (Spindle.Event.make count 1)
```

- **An event is encoded once**, however many subscribers get it.
- **A client that leaves a quiet topic ends its producer.** The keep-alive
  it can no longer be sent resolves `Spindle.client_gone`, and
  `Broadcast.next ~until:gone` answers `None`, so the subscription and the
  connection are let go without waiting for the next event. Nothing is
  cancelled: a producer that does not pass `~until` learns at its next
  `send`.
- **A slow subscriber is dropped, never waited for.** One more than
  `~depth` events (16) behind gets `None` from `next`. So send whole
  states, not changes, and a client that reconnects is up to date.
- Each subscriber carries a tag (`()` here), which `Broadcast.subscribers`
  lists: who is present, say. `Broadcast.close` ends every subscription.

To read a stream from OCaml, see [the HTTP client](client.md#server-sent-events);
to test one, see [Testing event streams](testing.md#testing-event-streams).
