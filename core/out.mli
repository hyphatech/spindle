(** JSON as the generator writes it: in the order it was built, two spaces to a
    level, so a committed document changes only where the application did. *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | String of string
  | List of t list
  | Obj of (string * t) list
  | Raw of string  (** JSON already written -- an example, a tag -- as it is *)

val of_value : Wiretype.Value.t -> t
(** A value a schema was printed as, to be written in this layout. *)

val to_string : t -> string
(** Ending in a line break. *)

val json_string : string -> string
(** A string as a JSON string literal. *)
