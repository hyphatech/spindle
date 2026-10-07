(** A CORS policy as the server applies it: what {!Cors.make} makes, and the
    fields of the Fetch standard's answers it owes a cross-origin request. *)

type origins = Origins of string list | Any

type t = {
  origins : origins;
  credentials : bool;
  headers : string list;  (** lower-cased, as they are compared *)
  expose : string list;
  max_age_s : int;
  routes : Route_repr.info -> bool;
}

val covers : t -> Route_repr.info -> bool
(** Whether the policy is the route's. *)

val trusts : t -> origin:string -> cookie:bool -> bool
(** Whether a write from [origin] is believed: a named origin always, and under
    [Any] only a request carrying no cookie, since a form another site posts is
    never preflighted and would ride a session. *)

val preflight :
  t ->
  origin:string ->
  allow:Spindle_http.Meth.t list ->
  requested:string option ->
  (string * string) list
(** The answer to a preflight from [origin] for a path [allow]ed those methods,
    the headers it [requested] granted where the policy allows them; only the
    [Vary] fields where the origin is not allowed. *)

val answer_headers : t -> origin:string option -> (string * string) list
(** The fields an answer to a cross-origin request carries. *)
