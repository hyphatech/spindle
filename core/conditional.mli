(** A [GET] of a representation: RFC 9110 §13.2.2's preconditions in their
    order, then §14's range: one account for every file the framework serves. *)

type validators = {
  tag : Spindle_http.Etag.t;
  modified_ms : int option;  (** where the representation has a date *)
}

(** What a request's preconditions and range come to. *)
type answer =
  | Precondition_failed  (** [412] *)
  | Not_modified  (** [304] *)
  | Whole  (** [200], the whole representation *)
  | Part of { first : int; last : int }  (** [206], those bytes *)
  | Unsatisfiable  (** [416] *)

val inputs : Request.t Dep.t
(** The request, its conditional and range headers listed, so a route that
    answers a file declares them. *)

val decide : Request.t -> validators -> length:int -> answer
(** The answer the request's preconditions and range owe a representation of
    [length] bytes. *)

val representation_headers :
  validators -> headers:(string * string) list -> (string * string) list
(** [Accept-Ranges], the tag and the date, before [headers]. *)

val bodiless_response :
  validators ->
  headers:(string * string) list ->
  length:int ->
  answer ->
  Response.t option
(** The answer where it carries no body -- [412], [304] with the tag alone,
    [416] with the length -- and [None] where it carries the representation. *)
