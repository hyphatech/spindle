(** A request's body while a route runs: read whole once and kept for every
    dependency that asks, or handed to the one that streams it. What {!Body} is,
    underneath. *)

type error = Request_repr.body_error

type source = {
  whole : unit -> (string, error) result;
  part : max:int -> ([ `Data of string | `End ], error) result;
}
(** Where the connection loop hands the body over, whole or a part at a time. *)

type held = {
  source : source;
  pattern : string;  (** the route's, for the log *)
  mutable read : (string, error) result option;
  mutable streamed : bool;
  mutable handler_returned : bool;
}
(** One request's body, as its dependencies share it. *)

type t = {
  held : held;
  max : int;
  mutable failed : error option;
  mutable ended : bool;
}
(** The body as a stream, read a part of at most [max] bytes at a time. *)

val hold : source -> pattern:string -> held

val refusal : error -> Refusal.t
(** [413], [503 busy] or [400], as the body failed. *)

val whole : held -> (string, error) result
(** The body read whole, once however many ask; [Unreadable] after it was read
    as a stream, which left nothing whole. *)

val stream : held -> max:int -> t
(** The body as a stream; reading it whole after is refused. *)

val end_handler : held -> unit
(** Marks the route's handler returned, after which the body is the connection
    loop's again. *)
