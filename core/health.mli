(** Whether the server is up, and whether it can serve: [GET /livez] and
    [GET /readyz], the two questions an orchestrator, a load balancer or a
    person asks of a running server. They are routes, added to the application's
    own, and a check reads what it asks about as a route does, so they are made
    with the rest before any of it exists:

    {[
    let routes =
      app_routes @ Spindle.Health.routes [ Spindle_postgres.Pool.check db ]

    let () =
      Eio_main.run @@ fun env ->
      Spindle_postgres.Pool.run env database @@ fun pool ->
      Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
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

    Both write their access line at [debug] ({!Route.maker}'s [access_log]),
    since something asks every few seconds. *)

type check

val check : string -> (unit -> (unit, string) result) Dep.t -> check
(** [check name f]: [f] is a dependency, read for each probe -- a
    {!Dep.of_resource} the server is handed, or [Dep.return] for one that reads
    nothing -- and the function it gives answers [Ok ()] when what it checks can
    serve, and [Error why] when it cannot, [why] for the log. [name] is what the
    refusal names -- a word, such as [postgres] -- so it is for whoever runs the
    server. Only [/readyz] reads it, so [/livez] needs nothing the server holds.

    {[
    Spindle.Health.check "cache"
      (let+ cache = cache in
       fun () -> Cache.ping cache)
    ]} *)

val not_ready : Refusal.Code.t
(** [503 not_ready]: a check failed. *)

val routes :
  ?live:Path.path ->
  ?ready:Path.path ->
  ?guard:unit Dep.t ->
  check list ->
  Route.t list
(** [GET /livez] and [GET /readyz], or [live] and [ready]. Both are as public as
    any probe; an application that must not show them says who may with [guard],
    a dependency run first, whose refusal is the answer, as {!Metrics.routes}'
    is. *)
