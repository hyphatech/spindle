(** Request headers, typed:
    [Spindle.Header.optional "x-page" Spindle.Codec.int].

    As {!Query}, at [header.<name>]; a name is matched without regard to case,
    and a value is read trimmed. *)

val optional : string -> 'a Codec.t -> 'a option Dep.t
val required : string -> 'a Codec.t -> 'a Dep.t

val default : string -> 'a Codec.t -> 'a -> 'a Dep.t
(** The header's value, or the default when it is absent, said in the document.
*)
