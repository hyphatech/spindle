(** How often a key may call a route: a limit, and the dependency that holds a
    request to it.

    {[
    let sign_ins = Spindle.Rate.create ~mono_clock ~limit:10 ~per_s:1. ()

    (let+ () = Spindle.Rate.limit sign_ins ~key:Spindle.client and+ ... in ...)
    ]}

    {b A limit is a dependency}, so it is listed where the route is, and the
    route's document names its [429]: a request past it is refused with
    {!Refusal.Code.rate_limited}, which {!limit} declares -- no route that reads
    none may answer it -- with [Retry-After] in whole seconds.

    {b It is GCRA}: one instant per key, the soonest it may call again, so a
    check is a comparison and a write, exact, with bursts. The table is behind a
    lock held for that alone, and a key whose instant has passed is dropped
    every thousand writes, so it holds only keys that are limited. Durations are
    the monotonic clock's, which a wall clock that jumps cannot move; a test
    gives it [Eio_mock]'s. It is one process's. Behind a proxy, a key that is
    the client's address is the one [trusted_proxies] vouches for
    ({!Spindle.client}). *)

type t

val create :
  mono_clock:_ Eio.Time.Mono.t ->
  limit:int ->
  per_s:float ->
  ?burst:int ->
  unit ->
  t
(** [limit] calls every [per_s] seconds, up to [burst] ([limit]) of them at
    once. *)

val limit : t -> key:string Dep.t -> unit Dep.t
(** The request counted against its key -- the client's address, a session, a
    token, a path parameter -- or refused past the limit. *)
