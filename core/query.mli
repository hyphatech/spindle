(** Query parameters, typed: [Spindle.Query.optional "page" Spindle.Codec.int].

    Each is a dependency that says what it reads, by name and
    {!Codec.type-shape}. A value that does not parse is {!Refusal.invalid} at
    [query.<name>], and a required one that is missing is too -- reported with
    every other problem of the request, at once. *)

val optional : string -> 'a Codec.t -> 'a option Dep.t
(** The first value given, if any. *)

val required : string -> 'a Codec.t -> 'a Dep.t

val list : string -> 'a Codec.t -> 'a list Dep.t
(** Every value given -- [?tag=a&tag=b] -- in order; none is the empty list. *)
