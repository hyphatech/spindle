(** Entity tags, as RFC 9110 §8.8.3 writes them, and the two ways §8.8.3.2
    compares them.

    {[
    Etag.parse {|W/"xyzzy"|} = Ok { weak = true; opaque = "xyzzy" }
    Etag.condition {|"a", W/"b"|} = Ok (Tags [ ...; ... ])
    ]}

    An opaque tag may hold a comma, so a list of them is read by this grammar
    and never split where a comma is. *)

type t = {
  weak : bool;
      (** written [W/"..."]: a representation equivalent, not identical *)
  opaque : string;
      (** what is between the quotes: [etagc], RFC 9110's visible characters but
          [DQUOTE], and [obs-text] *)
}

val parse : string -> (t, string) result
(** One entity tag, and the whitespace around it. *)

val to_string : t -> (string, string) result
(** [W/"opaque"] or ["opaque"], as {!parse} reads it back, or [Error] for an
    opaque tag holding a quote, a space or a control character. *)

val strong_equal : t -> t -> bool
(** Both strong, and the same opaque tag: what [If-Match] and [If-Range] ask. *)

val weak_equal : t -> t -> bool
(** The same opaque tag, either weak or not: what [If-None-Match] asks. *)

(** What [If-Match] and [If-None-Match] hold. *)
type condition = Any  (** [*] *) | Tags of t list

val condition : string -> (condition, string) result
(** A field's value, its lines joined with commas as RFC 9110 §5.3 allows. *)
