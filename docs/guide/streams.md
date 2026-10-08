# Server-Sent Events

A Server-Sent Events stream sends events until it is done. `Broadcast`
sends one event to everyone listening.

## A resumable event stream

`GET /count` sends a number a second, and a client that reconnects carries
on where it left off:

```ocaml
--8<-- "sse.ml"
```

```sh
curl -N localhost:8080/count
```

```text
event: count
id: 1
data: 1

event: count
id: 2
data: 2
...
```

```sh
curl -N -H 'Last-Event-ID: 41' localhost:8080/count
```

```text
event: count
id: 42
data: 42
...
```

- **Declare each kind of event**: `Event.json "count" Wiretype.int`, or
  `Event.text "token"` for plain text. The stream's own type (`counting`)
  stops you sending another stream's events.
- **`send` answers `Error Gone` once the client has gone**, so a loop
  written with `let*` ends there.
- **Resuming:** give each event an id (`Event.make ~id`). A browser sends
  the last one back as `Last-Event-ID` when it reconnects.
- A quiet stream gets a `: keep-alive` comment every 15 seconds
  (`Returns.events ~keep_alive_s`).

## Broadcasting to many clients

`Broadcast` sends one event to every subscriber of a topic, within one
process:

```ocaml
open Spindle.Syntax

let ( let* ) = Result.bind

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
    (let+ room = Spindle.param room in
     Ok
       (fun send ->
         let sub = Spindle.Broadcast.subscribe hub ~topic:room () in
         Fun.protect
           ~finally:(fun () -> Spindle.Broadcast.unsubscribe hub sub)
           (fun () ->
             let rec loop () =
               match Spindle.Broadcast.next sub with
               | Some event ->
                   let* () = send event in
                   loop ()
               | None -> Ok () (* dropped as slow, or unsubscribed *)
             in
             loop ())))

(* Anywhere else: make the event once, and everybody gets it. *)
let () =
  Spindle.Broadcast.publish hub ~topic:"lobby" (Spindle.Event.make count 1)
```

- **An event is encoded once**, however many subscribers get it.
- **A slow subscriber is dropped, never waited for.** One more than
  `~depth` events (16) behind gets `None` from `next`. So send whole
  states, not changes, and a client that reconnects is up to date.
- Each subscriber carries a tag (`()` here), which `Broadcast.subscribers`
  lists: who is present, say. `Broadcast.close` ends every subscription.
