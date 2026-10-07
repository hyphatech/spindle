(** Whether the server is up, and whether it can serve: [GET /livez] and
    [GET /readyz], the two questions an orchestrator, a load balancer or a
    person asks of a running server. They are routes, added to the application's
    own:

    {[
    Spindle.serve env
      (routes @ Spindle.Health.routes [ Spindle_postgres.Pool.check pool ])
    ]}

    {b [/livez] runs no check.} It answers [ok] for as long as the process can
    answer at all, because what a failed liveness probe asks for is a restart,
    and a restart mends nothing a database's outage broke: it would restart
    every instance at once.

    {b [/readyz] runs every check}, side by side, and answers [ok] or
    [503 not_ready] naming the checks that failed. Why each failed is a [warn]
    line on {!Log.http} and nowhere else: a database that is down is degraded,
    not our bug. A platform that probes one path is pointed at this one.

    How long to wait is the prober's to say, as every prober does, and a check
    that waits on something bounds its own wait -- the pool's borrow and its
    statement timeout -- so the framework keeps no deadline of its own.

    A server that is stopping needs no check to say so: it stops accepting when
    told to stop, so a probe's next connection is refused, and every answer
    while it drains says [Connection: close].

    Both write their access line at [debug] ({!Meta.access}), since something
    asks every few seconds. *)

type check

val check : string -> (unit -> (unit, string) result) -> check
(** [check name f]: [f] answers [Ok ()] when what it checks can serve, and
    [Error why] when it cannot, [why] for the log. [name] is what the refusal
    names -- a word, such as [postgres] -- so it is for whoever runs the server.
*)

val not_ready : Refusal.Code.t
(** [503 not_ready]: a check failed. *)

val routes : ?live:Path.path -> ?ready:Path.path -> check list -> Route.t list
(** [GET /livez] and [GET /readyz], or [live] and [ready]. *)
