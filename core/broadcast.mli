(** One event, rendered once, sent to everybody listening to a topic.

    There is no broker. A broker exists to carry an event from one process to a
    socket held by another, and in one process three hundred listeners are three
    hundred fibers parked on a read, which is the thing Eio is good at. What the
    load actually demands is two rules, and both are here.

    {b The publisher renders once.} {!publish} takes the event already rendered
    -- an {!Event.t}, or the bytes it goes out as -- and hands that one value to
    every subscriber. Rendering per subscriber would be three hundred renderings
    of one change.

    {b A slow subscriber is dropped, never waited for.} Each has a bounded
    queue; one that fills up is disconnected instead of pushing back on
    everybody else. That is only safe when an event is a whole state rather than
    a delta -- a reconnection is then a correction, and whatever anybody missed
    is in the database -- which is the application's to make true.

    Each subscriber carries a tag of the application's choosing -- who it is
    present as, say -- which {!subscribers} answers and nothing here reads. *)

type ('tag, 'event) t
type ('tag, 'event) subscription

val create : ?depth:int -> unit -> ('tag, 'event) t
(** [depth] (16) is how far behind a subscriber may fall before it is dropped.
    Raises [Invalid_argument] for a depth below one, which would drop every
    subscriber at the first event: it is a constant written in source. *)

val subscribe :
  ('tag, 'event) t ->
  topic:string ->
  'tag ->
  (('tag, 'event) subscription -> 'a) ->
  'a
(** [subscribe t ~topic tag f] subscribes to [topic] as [tag], runs [f] with the
    subscription, and unsubscribes however [f] ends -- returned, raised or
    cancelled -- so a subscription lasts as long as the work that reads it and
    no longer. Subscribing first and then reading the state a route sends before
    the changes is what makes a change published in between arrive.

    {[
    Spindle.Broadcast.subscribe hub ~topic:room () (fun sub ->
        Spindle.Broadcast.forward ~until:gone sub send)
    ]} *)

val unsubscribe : ('tag, 'event) t -> ('tag, 'event) subscription -> unit
(** Ends a subscription before its work does -- another fiber's, say, whose
    reader then answers as one dropped. Once ended, nothing more happens. *)

val next :
  ?until:unit Eio.Promise.t -> ('tag, 'event) subscription -> 'event option
(** The next event, waiting until there is one: for a reader that takes one
    event and does something else, where a loop that sends each is {!forward}.
    [None] once the subscriber has been dropped or unsubscribed -- and again
    every time after -- and once [until] is resolved. With [until], each wait
    races the queue against it, which costs a loop about three times what
    {!forward}'s one watcher does. An event that arrives as [until] resolves may
    be lost with it. *)

val forward :
  ?until:unit Eio.Promise.t ->
  ('tag, 'event) subscription ->
  ('event -> (unit, 'e) result) ->
  (unit, 'e) result
(** [forward ?until sub send] hands every event to [send], in order, and answers
    [Ok ()] once the subscriber is dropped as slow, unsubscribed or closed, or
    the first [Error] [send] answers. [until] -- a stream's
    {!Spindle.client_gone}, so one on a quiet topic ends when its client goes
    rather than at the next event -- resolving unsubscribes it as {!unsubscribe}
    does: {!subscribers} stops listing it at once, a [send] already running
    finishes, and nothing is cancelled. An [until] already resolved hands on
    nothing.

    {[
    Spindle.Broadcast.forward ~until:gone sub (fun order ->
        if Order.visible_to user order then send order else Ok ())
    ]} *)

val dropped : ('tag, 'event) subscription -> bool
(** Whether the hub dropped this subscriber as slow: [false] while it is
    subscribed, and after it was unsubscribed or its hub closed. A reader that
    {!forward} or {!next} has ended asks it to tell a drop, which missed events
    and should come back, from an end, which should not. *)

val close : ('tag, 'event) t -> unit
(** Unsubscribes everybody on every topic: each {!forward} answers [Ok ()] and
    each {!next} [None], which is how a server that is stopping ends its
    streams. *)

val publish : ('tag, 'event) t -> topic:string -> 'event -> unit
(** Never blocks: a subscriber that cannot keep up is dropped here. *)

val topics : ('tag, 'event) t -> string list
(** Every topic somebody is subscribed to. *)

val subscribers : ('tag, 'event) t -> topic:string -> 'tag list
(** The tags of everybody subscribed to [topic] right now. *)
