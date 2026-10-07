(** A path as the framework reads it: its segments and each parameter's codec.
    What {!Path} is, underneath, and what the router matches. *)

type 'a spec = {
  name : string;
  codec : 'a Codec.t;
  or_not_found : bool;
  rest : bool;
      (** every remaining segment, read as the matcher hands them over: each
          encoded again and joined by ["/"], so a segment holding an encoded
          ["/"] stays one segment *)
}

type part = Fixed of string | Variable : 'a spec -> part

(** The kind keeps a joined path out of {!Spindle.param}. *)
type ('a, 'kind) t =
  | Param : 'a spec -> ('a, [ `Param ]) t
  | Path : part list -> (unit, [ `Path ]) t

val parts_of : ('a, 'kind) t -> part list

(** A segment as the matcher reads it: a parameter is asked only whether it
    parses. *)
type segment =
  | Literal of string
  | Parameter of {
      name : string;
      or_not_found : bool;
      parses : string -> bool;
      shape : Codec.shape;
      kind : string option;
    }
  | Rest of string

val segments : ('a, 'kind) t -> segment list

val encode : string -> string
(** Every byte but RFC 3986's unreserved characters percent-encoded, so any text
    is one segment. *)

val join_rest : string list -> string
(** What the matcher hands a rest parameter: each segment encoded, joined by
    ["/"]. *)

val rest_codec : string list Codec.t
(** A rest parameter's codec: the joined segments, each decoded. *)
