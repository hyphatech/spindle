(** A media type, as [Content-Type] holds one (RFC 9110 §8.3.1): a type, a
    subtype and parameters.

    {[
    Media_type.parse {|application/json; charset="utf-8"|}
    = Ok
        {
          type_ = "application";
          subtype = "json";
          parameters = [ ("charset", "utf-8") ];
        }
    ]} *)

type t = {
  type_ : string;  (** lower-cased, as it is compared *)
  subtype : string;  (** lower-cased *)
  parameters : (string * string) list;
      (** in the order given, each name lower-cased and each value as it came, a
          quoted string's escapes undone *)
}

val parse : string -> (t, string) result
(** A field's value as one media type, and nothing after it; a parameter given
    twice is an [Error] (RFC 6838 §4.3), in words for a log. *)

val to_string : t -> (string, string) result
(** [type/subtype], then each parameter as [; name=value], its value a quoted
    string where it is not a token, or [Error] for what {!parse} would not read
    back as itself: a type or a name that is no token or is not lower-cased, a
    parameter twice, a value no quoted string can hold. *)

val equal : t -> t -> bool
(** The same type, subtype and parameters, in the same order. *)

val parameter : t -> string -> string option
(** The first value of the parameter named, whatever the name's case. *)
