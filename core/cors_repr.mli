(** A CORS policy as the server applies it: what {!Cors.origins} or {!Cors.any}
    makes, and the fields of the Fetch standard's answers it owes a cross-origin
    request. *)

type origins = Origins of string list | Any

type policy = {
  origins : origins;
  credentials : bool;
  headers : string list;  (** lower-cased, as they are compared *)
  expose : string list;
  max_age_s : int;
}

type t = policy option
(** [None] allows no other site. *)

val allows : policy -> string -> bool
(** Whether the policy lets [origin] read an answer. *)

val trusts : policy -> origin:string -> ambient_credential:bool -> bool
(** Whether a write from [origin] is believed: a named origin always, and under
    [Any] only a request carrying no credential the browser attached itself -- a
    cookie, or HTTP authentication it has cached -- since a form another site
    posts is never preflighted and would ride it. *)

val preflight :
  policy ->
  origin:string ->
  allow:Spindle_http.Meth.t list ->
  requested:string option ->
  (string * string) list
(** The answer to a preflight from [origin] for a path [allow]ed those methods,
    the headers it [requested] granted where the policy allows them; only the
    [Vary] fields where the origin is not allowed. *)

val answer_headers : policy -> origin:string option -> (string * string) list
(** The fields an answer to a cross-origin request carries. *)
