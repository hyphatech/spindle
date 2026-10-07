# Streams and broadcast

A Server-Sent Events stream is an answer that declares its events: each kind
by name and what its data is -- JSON of a description,
`Event.json "state" state_json`, or text as it is, `Event.text "token"`.
A stream's events are a type of its own, declared and never defined, which
each of its kinds carries, so `send` takes no event made for another stream;
one of its own kinds the route left out of its list is sent, and logged as
its bug. An event is made from its kind -- encoded once, then sent to as
many clients as are listening -- and `Event.retry` and `Event.comment` are
the two lines any stream may send. A value its kind cannot encode is our
bug, logged where it is made, and that event sends nothing. `send` answers
a result, `Error Gone` once the client has gone, so a producer's loop is
written with `let*` and ends there; one waiting for something to send when
its client goes learns it at its next `send`, since nothing cancels it. The framework writes the chunked
framing, the no-buffering headers, a `: keep-alive` comment whenever the
stream has been quiet for `Returns.events ~keep_alive_s` (15) seconds, and a
log line when the stream ends and why (finished, client gone, connection
closed). The document describes each event as OpenAPI 3.2 does, an
`itemSchema` with a branch per name.

**Resuming** is an id on each event, `Event.make ~id`, which a browser sends
back as `Last-Event-ID` when it reconnects; the route reads it as it reads
any header, `Spindle.Header.optional "last-event-id" Spindle.Codec.int`, and
carries on after it. This stream resumes:

```ocaml
--8<-- "sse.ml"
```

```ocaml
type room

let count : (int, room) Spindle.Event.kind = Spindle.Event.json "count" Wiretype.int
let hub : (unit, room Spindle.Event.t) Spindle.Broadcast.t =
  Spindle.Broadcast.create ~depth:16 ()

let room = Path.str "room"

let events =
  Spindle.get
    Path.(s "rooms" / room / s "events")
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

(* Anywhere else: make it once, send the same event to everybody. *)
let () = Spindle.Broadcast.publish hub ~topic:"lobby" (Spindle.Event.make count 1)
```

`Broadcast` is in-process fan-out with two rules: **the publisher renders
once** (`publish` takes what it sends already made -- an `Event.t`, or
bytes), and **a slow subscriber is dropped, never
waited for** (a bounded queue per subscriber). The second is only safe when
every event is a whole state, which is the application's to make true.
