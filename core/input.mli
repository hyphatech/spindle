(** Reading a typed input: a query parameter, a header, a cookie or a path
    parameter, told apart only by where its text comes from, each read by its
    wiretype description as [Wiretype.of_text] reads one. {!Query}, {!Header},
    the cookie inputs and {!Spindle.param} are built on this, and nothing
    outside the library reaches it. *)

type source

val query : source
val header : source
val cookie : source

val optional :
  ?joined:bool -> source -> string -> 'a Wiretype.t -> 'a option Dep.t
(** [joined] reads a header's lines as one list field (RFC 9110 §5.3). *)

val default : source -> string -> 'a Wiretype.t -> 'a -> 'a Dep.t
(** Raises [Invalid_argument] for a default its description will not write. *)

val required : source -> string -> 'a Wiretype.t -> 'a Dep.t
val list : source -> string -> 'a Wiretype.t -> 'a list Dep.t
val param : 'a Path.param -> 'a Dep.t

val parse : at:string -> 'a Wiretype.t -> string -> ('a, Refusal.t) result
(** A value read by its description, or its problems, each at [at], for every
    input, a form's field among them. *)

val missing : at:string -> Refusal.t
(** The problem of a required input not given. *)
