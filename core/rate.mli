(** How often a key may call a route: a limit, and the dependency that holds a
    request to it.

    {[
    let sign_ins = Spindle.Rate.create ~limit:10 ~per:Mtime.Span.s ()

    (let+ () = Spindle.Rate.limit sign_ins ~key:Spindle.client_ip and+ ... in ...)
    ]}

    {b A limit is a dependency}, so it is listed where the route is, and the
    route's document names its [429]: a request past it is refused with
    {!Refusal.Code.rate_limited}, which {!limit} declares -- no route that reads
    none may answer it -- with [Retry-After] in whole seconds.

    {b It is GCRA}: one instant per key, the soonest it may call again, so a
    check is a comparison and a write, exact, with bursts. The table is behind a
    lock held for that alone, and a key whose instant has passed is dropped
    every thousand writes, so it holds only keys that are limited.

    {b A limit is a value, and its counts are its app's}: one made at the top
    level holds none, and each app that serves it counts its own, so two apps --
    two servers, two tests -- never share a key's. Durations are the app's
    monotonic clock's, which a wall clock that jumps cannot move: the one
    {!App.start} is given, which {!Spindle.serve} gives the environment's, or
    {!Test.app}'s. Counts are one process's. Behind a proxy, a key that is the
    client's address is the one [trusted_proxies] vouches for
    ({!Spindle.client_ip}). *)

type t

val create : limit:int -> per:Mtime.Span.t -> ?burst:int -> unit -> t
(** [limit] calls every [per], up to [burst] ([limit]) of them at once. Raises
    [Invalid_argument] for a [limit] or a [burst] below one, or a [per] shorter
    than [limit] nanoseconds, which leaves no time between two calls: each would
    limit nothing or everything, and is a constant written in source. *)

val limit : t -> key:string Dep.t -> unit Dep.t
(** The request counted against its key -- the client's address, a session, a
    token, a path parameter -- or refused past the limit. A key that is an IPv6
    address is counted by its /64, within which a client makes its own address
    and may change it at will, so rotating addresses is one key; an IPv4
    address, or one mapped into IPv6, by the address itself. *)
