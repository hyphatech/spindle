(** A text input's description -- a path segment's, a query parameter's, a
    header's, a cookie's, a form's field's -- as the router, the readers and the
    document see it: what [Wiretype.Schema.walk] says of it, and its kind's
    name. Nothing outside the library reaches it. *)

val schema : 'a Wiretype.t -> Wiretype.Schema.t
(** What a request's input is, walked as a body read from a request is. *)

val kind : 'a Wiretype.t -> string option
(** The name of an enum or a kind the description was given, if any. *)

val scalar : Wiretype.Schema.t -> bool
(** Whether a value of it is one text: a string, a number, an integer or a
    boolean, as [Wiretype.of_text] reads one. *)

val default : at:string -> 'a Wiretype.t -> 'a -> Wiretype.Value.t
(** A default as the JSON its description writes, for the document. Raises
    [Invalid_argument] for one its description refuses to write -- outside its
    bounds -- naming the input at [at]: a default is a constant in source. *)
