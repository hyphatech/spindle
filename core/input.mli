(** Reading a typed input: a query parameter, a header, a cookie or a path
    parameter, told apart only by where its text comes from. {!Query},
    {!Header}, the cookie inputs and {!Spindle.param} are built on this, and
    nothing outside the library reaches it. *)

type source

val query : source
val header : source
val cookie : source
val optional : source -> string -> 'a Codec.t -> 'a option Dep.t
val required : source -> string -> 'a Codec.t -> 'a Dep.t
val list : source -> string -> 'a Codec.t -> 'a list Dep.t
val param : 'a Path.param -> 'a Dep.t

val malformed : at:string -> 'a Codec.t -> Refusal.t
(** The problem of a value its codec does not read, at [at]: one sentence for
    every input, a form's field among them. *)

val missing : at:string -> Refusal.t
(** The problem of a required input not given. *)
