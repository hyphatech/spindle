(** Content negotiation, as RFC 9110 §12 writes it: what a request accepts, each
    with its weight, and choosing among what a route can answer.

    {[
    match Accept.parse_media "text/csv;q=0.9, application/json" with
    | Ok ranges -> Accept.choose_media ranges [ csv; json ] (* Some json *)
    | Error _ -> None
    ]}

    A weight is thousandths, 0 to 1000: RFC 9110 §12.4.2 allows three decimals,
    so [q=0.5] is 500 and a range with no [q] is 1000. *)

type range = {
  type_ : string;  (** lower-cased, or ["*"] *)
  subtype : string;  (** lower-cased, or ["*"] *)
  parameters : (string * string) list;
      (** those before [q], as a media type's *)
  weight : int;
}

val parse_media : string -> (range list, string) result
(** An [Accept] value: each media range, in order, with its weight. A [q] that
    is no quality value, or a parameter after it, is an [Error]. *)

val parse_weighted : string -> ((string * int) list, string) result
(** An [Accept-Language], [Accept-Encoding] or [Accept-Charset] value: each
    token, lower-cased since all three compare it without case, with its weight.
*)

val choose_media : range list -> Media_type.t list -> Media_type.t option
(** The offer a client would rather have, of those it accepts at all: each
    offer's weight is that of the most specific range that matches it -- a type
    and subtype with parameters over one without, over [type/*], over [*/*] --
    and a weight of 0 is not accepted. A tie goes to the earlier offer, so the
    list is the route's own order of preference. No range at all accepts
    everything, and chooses the first offer. *)

val choose_language : (string * int) list -> string list -> string option
(** The same for language tags, a range matching a tag it equals or begins with,
    followed by a hyphen -- [en] matches [en-GB] -- as RFC 4647 §3.3.1's basic
    filtering has it, and [*] every tag; the longest range that matches decides.
*)

val choose_encoding : (string * int) list -> string list -> string option
(** The same for content codings, with [identity]'s own rule (RFC 9110 §12.5.3):
    it is acceptable unless the list excludes it, by name or by [*] with a
    weight of 0 -- and an empty list accepts [identity] alone. *)

val choose_token : (string * int) list -> string list -> string option
(** The same for any other token, [*] matching whatever is not named. *)
