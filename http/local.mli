(** What belongs to the domain a fiber runs on.

    Eio forks a fiber only onto a switch of the domain it is on: a switch made
    at startup cannot take a fiber forked from a request on another domain. So
    every domain Spindle runs has a switch of its own, which lasts as long as
    that domain serves, and work that outlives a request --
    [Spindle.Background], [Spindle.Alarm], a kept connection's watch -- is
    forked onto the switch of the domain that asked for it. *)

val switch : unit -> Eio.Switch.t option
(** The switch of the domain the calling fiber runs on: on every domain
    [Spindle.Server.run] serves on, and inside {!within}. [None] anywhere else
    -- a domain Spindle did not start, or no Eio loop at all. *)

val within : sw:Eio.Switch.t -> (unit -> 'a) -> 'a
(** [within ~sw f] runs [f] with [sw] as its domain's switch, for itself and
    every fiber it forks: an application's startup code and a test, which run
    outside any server. [sw] must be a switch of the calling domain; one that is
    not is answered as none by {!switch}, since forking onto it would raise. *)
