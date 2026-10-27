(** What {!Server.Limits} and {!Route.Limits} are, underneath: the connection
    loop reads both, a route's in place of the server's where it gave one, and
    {!Test} applies them as the loop does. *)

type server = {
  max_body : int;
  max_header_bytes : int;
  head_timeout : Mtime.Span.t;
  idle_timeout : Mtime.Span.t;
  body_timeout : Mtime.Span.t;
  min_body_rate : int;
  handler_timeout : Mtime.Span.t;
  send_timeout : Mtime.Span.t;
  discard_limit : int;
  linger : Mtime.Span.t;
  body_budget : int;
  max_connections : int;
  backlog : int;
  drain : Mtime.Span.t;
}

type route = {
  max_body : int option;
  body_timeout : Mtime.Span.t option;
  min_body_rate : int option;
  handler_timeout : Mtime.Span.t option;
}
(** A route's own, each [None] where it has the server's. *)

val no_route : route
(** A route that gave none. *)

val check_count : who:string -> string -> least:int -> int -> unit
(** Raises [Invalid_argument], naming [who] and the limit, for a count below
    [least]. *)

val check_wait : who:string -> string -> Mtime.Span.t -> unit
(** Raises [Invalid_argument], naming [who] and the limit, for a wait of zero.
*)
