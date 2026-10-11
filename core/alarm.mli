(** Wake-ups, one per key: "look at this again after so long".

    Setting a key again supersedes what was set before: the earlier wake-up's
    fiber is cancelled, not left asleep, and a key is forgotten once it has
    fired or been cancelled -- so a table of alarms holds only what is still to
    come, however many keys have been and gone. *)

type t

val create :
  ?slack:Mtime.Span.t ->
  background:Background.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  unit ->
  t
(** Wake-ups are forks of [background], each on the domain whose fiber set it,
    timed on [mono_clock], which is monotonic so that a wall clock that jumps
    moves none of them. A key may be set, and set again, from any domain. *)

val set :
  t -> key:string -> after:Mtime.Span.t -> what:string -> (unit -> unit) -> unit
(** [set t ~key ~after ~what f] runs [f] [slack] (50 ms) past [after] from now
    -- past rather than on, so that arithmetic on the other side has
    unambiguously passed the instant -- unless [key] is set again or cancelled
    first. [what] names it in the log if [f] raises; a raise is logged and never
    reaches anybody. A wake-up at an instant is set for the wait until it,
    {!Spindle.until}:

    {[
    Spindle.Alarm.set alarms ~key ~after:(Spindle.until ~now deadline)
      ~what:"a turn's clock" (fun () -> end_turn game)
    ]} *)

val cancel : t -> key:string -> unit
(** Whatever is set for [key] never runs. *)
