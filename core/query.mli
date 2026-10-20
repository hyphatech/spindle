(** Query parameters, typed: [Spindle.Query.optional "page" Spindle.Codec.int].

    Each is a dependency that says what it reads, by name and
    {!Codec.type-shape}. A value that does not parse is {!Refusal.invalid} at
    [query.<name>], and a required one that is missing is too -- reported with
    every other problem of the request, at once.

    A parameter sent more than once, [?role=viewer&role=admin], is read by its
    first value, as the URL standard's [URLSearchParams.get] reads it and as the
    client that wrote the URL reads it back; {!list} reads every one. Such a URL
    is valid, so it never fails a route, and no value is made that was not sent,
    as joining them would. *)

val optional : string -> 'a Codec.t -> 'a option Dep.t
(** The first value given, if any. *)

val required : string -> 'a Codec.t -> 'a Dep.t

val default : string -> 'a Codec.t -> 'a -> 'a Dep.t
(** [default "page" Codec.int 1]: the value given, or [1] when there is none,
    and the default said in the document. A value that does not parse is
    refused, as {!optional}'s is. *)

val list : string -> 'a Codec.t -> 'a list Dep.t
(** Every value given -- [?tag=a&tag=b] -- in order; none is the empty list. *)
