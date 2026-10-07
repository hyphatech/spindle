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
  ('tag, 'event) t -> topic:string -> 'tag -> ('tag, 'event) subscription

val unsubscribe : ('tag, 'event) t -> ('tag, 'event) subscription -> unit

val next : ('tag, 'event) subscription -> 'event option
(** The next event, waiting until there is one. [None] once the subscriber has
    been dropped or unsubscribed -- and again every time after -- which is how
    the fiber writing it to a socket learns to stop. *)

val close : ('tag, 'event) t -> unit
(** Unsubscribes everybody on every topic: each {!next} answers [None], which is
    how a server that is stopping ends its streams. *)

val publish : ('tag, 'event) t -> topic:string -> 'event -> unit
(** Never blocks: a subscriber that cannot keep up is dropped here. *)

val topics : ('tag, 'event) t -> string list
(** Every topic somebody is subscribed to. *)

val subscribers : ('tag, 'event) t -> topic:string -> 'tag list
(** The tags of everybody subscribed to [topic] right now. *)
