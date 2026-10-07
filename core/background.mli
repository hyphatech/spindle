(** Work nobody is waiting for.

    A daemon, so a process shutting down is not held open by one. A failure is
    {b logged}, never raised: a fiber's exception fails the switch it was forked
    on, and when that switch is the server's, one bug in a background job would
    take every request down with it. Cancellation still passes, because that is
    the server going away and not a failure.

    {b It runs where it was caused.} A fork from a fiber on a domain Spindle
    runs goes onto that domain's own switch ({!Local}) -- Eio forks onto no
    other -- so work started by a request on one domain runs there, with no
    message and no domain that all of it funnels through. A fork from a domain
    Spindle does not run -- an [Executor_pool] worker of the application's -- is
    posted to the one fiber {!create} started, and runs on its domain. *)

type t

val create : sw:Eio.Switch.t -> t
(** At startup, on the domain that owns [sw]: [sw] is where a fork outside any
    domain Spindle runs goes -- the application's own startup code, and work
    posted from a domain of its own -- and it holds the fiber that takes what is
    posted. *)

val fork : t -> what:string -> (unit -> unit) -> unit
(** [fork t ~what f] runs [f] on a fiber of its own, and returns at once. [what]
    names it in the [error] line a failure writes, on [spindle.background]; the
    line carries the id of the request that forked it, when one did. *)
