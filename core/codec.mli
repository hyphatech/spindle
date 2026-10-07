(** Codecs: how one piece of text in a request -- a path segment, a query
    parameter, a header, a cookie -- is read as a value, and written back.

    {[
    let page = Spindle.Query.optional "page" Spindle.Codec.int

    let colour =
      Spindle.Path.param "colour"
        (Codec.enum ~kind:"colour" Colour.to_string Colour.[ Red; Green ])
    ]}

    One codec reads the same way wherever the text arrives, and says what it
    reads as a {!type-shape}, so a document generated from the routes can
    describe the input exactly. *)

type 'a t

(** What a codec reads, for whatever describes it. *)
type shape =
  | String
  | Format of Wiretype.Shape.format  (** a string written in this format *)
  | Integer
  | Number
  | Boolean
  | Enum of string list  (** exactly these words *)

val string : string t
(** Any text, as it arrived (decoded). *)

val int : int t
(** A whole number in decimal digits, with an optional minus sign:
    [int_of_string] also reads ["0x1f"], ["1_000"] and ["+3"], none of which a
    client means. *)

val int64 : int64 t
(** {!int}'s rule, read as an [int64]: what most databases' keys are. *)

val float : float t
(** A number in decimal digits, with an optional minus sign, fraction and
    exponent: [21], [-7.5], [2.5e-4]. [float_of_string] also reads ["0x1p3"],
    ["inf"], ["nan"], [".5"] and ["+3"], none of which a client means, and a
    number too large for a float is refused rather than read as infinity. It
    prints the fewest digits that read back as the same float. *)

val uuid : string t
(** RFC 9562, any version, the nil and the max UUID included; printed
    lower-cased. *)

val date : (int * int * int) t
(** [(year, month, day)], as RFC 3339 [full-date]: [2026-09-30]. *)

val instant : int t
(** Epoch milliseconds, as {!Spindle.now} gives them, written as RFC 3339
    [date-time]: [2026-09-30T12:00:00Z], with any fraction and offset, printed
    in UTC with milliseconds. *)

val bool : bool t
(** [true] or [false], and nothing else. *)

val enum : kind:string -> ('a -> string) -> 'a list -> 'a t
(** One of a closed set of words: [enum ~kind:"colour" to_string [ Red; Green ]]
    reads ["red"] as [Red]. Each value is written as [to_string] writes it, and
    a word is read as the value that writes it, so there is nothing to keep in
    step. [kind] names the set. *)

val custom :
  kind:string ->
  ?expects:string ->
  parse:(string -> 'a option) ->
  print:('a -> string) ->
  unit ->
  'a t
(** A value of the application's own, read and written as text. [kind] names it;
    [expects] ends the sentence a client is told when a text is not one --
    ["This is not ..."] -- and is ["a valid <kind>"] unless given. Described as
    a string. *)

val parse : 'a t -> string -> 'a option
val print : 'a t -> 'a -> string

val expects : 'a t -> string
(** What a text has to be, as the end of ["This is not ..."]. *)

val shape : 'a t -> shape

val kind : 'a t -> string option
(** The name of an {!enum} or a {!custom} codec. *)

(** {1 A header's structure}

    Each read by its parser in {!Spindle_http}, so an application reads a
    structured header as an input like any other, and one that does not parse is
    [invalid] at its place. *)

val media_type : Spindle_http.Media_type.t t
(** A media type, as [Content-Type] holds one. *)

val credentials : Spindle_http.Auth.t t
(** Credentials, as [Authorization] holds them: a scheme, compared without case,
    and a token or parameters. A value that is not is [invalid] at its header,
    and never quoted. *)

val accept : Spindle_http.Accept.range list t
(** The media ranges in [Accept], each with its weight, for
    {!Spindle_http.Accept.choose_media} to choose among a route's answers. *)

val weighted : (string * int) list t
(** The tokens in [Accept-Language], [Accept-Encoding] or [Accept-Charset], each
    with its weight. *)

val cache_control : Spindle_http.Cache_control.t t
(** The directives in [Cache-Control], each with its argument. *)

val forwarded : Spindle_http.Forwarded.element list t
(** The proxies in [Forwarded], the nearest last. Believed only from a proxy the
    application trusts, which {!Request.client} already is. *)

val structured_item : Spindle_http.Structured.item t
(** A field defined as an RFC 9651 item, read as one; the field's definition
    says which of the three it is. A value no field can hold is written as
    nothing. *)

val structured_list : Spindle_http.Structured.member list t
val structured_dictionary : Spindle_http.Structured.dictionary t
