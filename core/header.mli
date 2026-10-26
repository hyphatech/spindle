(** Request headers, typed: [Spindle.Header.optional "x-page" Wiretype.int].

    As {!Query}, at [header.<name>]: a value is read by its wiretype
    description, as [Wiretype.of_text] reads one; a name is matched without
    regard to case, and a value is read trimmed.

    A header sent on several lines is one field (RFC 9110 §5.2). A field defined
    as a list -- [Accept], [Cache-Control], [Forwarded], an RFC 9651 list or
    dictionary -- is read with {!joined}, every line joined by [", "] as one
    value (§5.3). Every other reader reads a value sent once, and a header sent
    on more than one line is [malformed] at its place: a field that holds one
    value, sent twice, is an invalid message (§5.5), and reading its first line
    where a proxy read its last would be two readings of one request. *)

val optional : string -> 'a Wiretype.t -> 'a option Dep.t
val required : string -> 'a Wiretype.t -> 'a Dep.t

val default : string -> 'a Wiretype.t -> 'a -> 'a Dep.t
(** The header's value, or the default when it is absent, said in the document.
    Raises [Invalid_argument] for a default its description will not write --
    one outside its bounds: a constant written in source. *)

val joined : string -> 'a Wiretype.t -> 'a option Dep.t
(** A list field's every line, joined by [", "] and read as one value:
    [Header.joined "accept" Header.accept]. *)

(** {1 HTTP's values}

    Each a wiretype kind over the text, read by its parser in {!Spindle_http},
    so a structured header is an input like any other, and one that does not
    parse is [malformed] at its place. *)

val media_type : Spindle_http.Media_type.t Wiretype.t
(** A media type, as [Content-Type] holds one. *)

val credentials : Spindle_http.Auth.t Wiretype.t
(** Credentials, as [Authorization] holds them: a scheme, compared without case,
    and a token or parameters. A value that is not is [malformed] at its header,
    and never quoted. *)

val accept : Spindle_http.Accept.range list Wiretype.t
(** The media ranges in [Accept], each with its weight, for
    {!Spindle_http.Accept.choose_media} to choose among a route's answers. A
    list: read it with {!joined}. *)

val weighted : (string * int) list Wiretype.t
(** The tokens in [Accept-Language], [Accept-Encoding] or [Accept-Charset], each
    with its weight. A list. *)

val cache_control : Spindle_http.Cache_control.t Wiretype.t
(** The directives in [Cache-Control], each with its argument. A list. *)

val forwarded : Spindle_http.Forwarded.element list Wiretype.t
(** The proxies in [Forwarded], the nearest last. Believed only from a proxy the
    application trusts, which {!Request.client_ip} already is. A list. *)

val structured_item : Spindle_http.Structured.item Wiretype.t
(** A field defined as an RFC 9651 item, read as one; the field's definition
    says which of the three it is. A value no field can hold is written as
    nothing. *)

val structured_list : Spindle_http.Structured.member list Wiretype.t
(** A list. *)

val structured_dictionary : Spindle_http.Structured.dictionary Wiretype.t
(** A list. *)
