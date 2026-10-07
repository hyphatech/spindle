(** Byte ranges, as RFC 9110 §14 writes them: a request's [Range], and the
    [Content-Range] of an answer to one.

    {[
    Range.parse "bytes=0-499, -500" = Ok (Bytes [ Span (0, 499); Suffix 500 ])
    Range.satisfy ~length:1000 (Suffix 500) = Some (500, 999)
    Range.content_range ~first:500 ~last:999 ~length:1000 = "bytes 500-999/1000"
    ]} *)

(** One range, as a request writes it. *)
type spec =
  | From of int  (** [500-]: from there to the end *)
  | Span of int * int  (** [0-499]: both ends included *)
  | Suffix of int  (** [-500]: the last so many *)

type t =
  | Bytes of spec list  (** at least one *)
  | Other of string  (** a unit this is not, lower-cased, its ranges unread *)

val parse : string -> (t, string) result
(** A [Range] value. A span whose last position is before its first is an
    [Error], as §14.1.1 calls it invalid, and so is an empty list. A position
    too large to hold is the largest there is, which no length reaches. *)

val satisfy : length:int -> spec -> (int * int) option
(** The first and last byte it asks for of a representation [length] long, the
    last no further than its end; [None] when §14.1.1 calls it unsatisfiable --
    a range that starts past the end, or a suffix of nothing. *)

val content_range : first:int -> last:int -> length:int -> string
(** [bytes first-last/length], for a [206]. *)

val content_range_unsatisfied : length:int -> string
(** [bytes */length], for a [416]. *)
