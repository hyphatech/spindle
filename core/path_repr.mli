(** A path as the framework reads it: its segments and each parameter's
    description. What {!Path} is, underneath, and what the router matches. *)

type unparsed =
  | Invalid
  | Next_route
      (** What a segment its description cannot read makes of a request:
          {!Path.unparsed}. *)

type 'a spec = {
  name : string;
  description : 'a Wiretype.t;
  unparsed : unparsed;
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
      unparsed : unparsed;
      parses : string -> bool;
      schema : Wiretype.Schema.t;
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

val rest : string list Wiretype.t
(** A rest parameter's description: the joined segments, each decoded. *)
