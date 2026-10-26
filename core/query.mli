(** Query parameters, typed: [Spindle.Query.optional "page" Wiretype.int].

    Each is a dependency that says what it reads, by name and by its wiretype
    description, which reads its text as [Wiretype.of_text] does. A value its
    description does not read -- outside its bounds or not -- is
    {!Refusal.invalid} at [query.<name>] with the description's problems, and a
    required one that is missing is too -- reported with every other problem of
    the request, at once.

    A parameter sent more than once, [?role=viewer&role=admin], is read by its
    first value, as the URL standard's [URLSearchParams.get] reads it and as the
    client that wrote the URL reads it back; {!list} reads every one. Such a URL
    is valid, so it never fails a route, and no value is made that was not sent,
    as joining them would. *)

val optional : string -> 'a Wiretype.t -> 'a option Dep.t
(** The first value given, if any. *)

val required : string -> 'a Wiretype.t -> 'a Dep.t

val default : string -> 'a Wiretype.t -> 'a -> 'a Dep.t
(** [default "page" (Wiretype.int_bounded ~min:1 ()) 1]: the value given, or [1]
    when there is none, and the default said in the document. A value that does
    not read is refused, as {!optional}'s is. Raises [Invalid_argument] for a
    default its description will not write -- one outside its bounds: a constant
    written in source. *)

val list : string -> 'a Wiretype.t -> 'a list Dep.t
(** Every value given -- [?tag=a&tag=b] -- in order; none is the empty list. *)
