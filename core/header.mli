(** Request headers, typed:
    [Spindle.Header.optional "x-page" Spindle.Codec.int].

    As {!Query}, at [header.<name>]; a name is matched without regard to case,
    and a value is read trimmed.

    A header sent on several lines is one field (RFC 9110 §5.2). A codec of a
    list -- {!Codec.accept}, {!Codec.weighted}, {!Codec.cache_control},
    {!Codec.forwarded}, {!Codec.structured_list},
    {!Codec.structured_dictionary}, and a {!Codec.custom} given [~list:true] --
    reads every line, joined by [", "], as one value (§5.3). Any other codec
    reads a value sent once, and a header sent on more than one line is
    [malformed] at its place: a field that holds one value, sent twice, is an
    invalid message (§5.5), and reading its first line where a proxy read its
    last would be two readings of one request. *)

val optional : string -> 'a Codec.t -> 'a option Dep.t
val required : string -> 'a Codec.t -> 'a Dep.t

val default : string -> 'a Codec.t -> 'a -> 'a Dep.t
(** The header's value, or the default when it is absent, said in the document.
*)
