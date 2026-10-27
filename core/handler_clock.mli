(** How long a route's handler has run, its waits on its client's body left out:
    what [handler_timeout] bounds ({!Server.Limits}, {!Route.Limits}), since
    [body_timeout] and [min_body_rate] already bound those waits. One a request,
    kept by whatever hands the route its body. *)

type t

val create : _ Eio.Time.Mono.t -> t

val reading : t -> (unit -> 'a) -> 'a
(** [reading t read]: a wait on the client's body, not counted. *)

val within : t -> limit:Mtime.Span.t -> (unit -> 'a) -> ('a, unit) result
(** [within t ~limit handler]: the handler's answer, or [Error ()] once it has
    run [limit] outside its body's reads, when it is cancelled with everything
    it forked under it. *)

val refusal : route:string -> limit:Mtime.Span.t -> Response.t
(** The answer to a handler cancelled at its [limit]: {!Refusal.timed_out}, and
    a [warn] line naming the route and the limit. *)
