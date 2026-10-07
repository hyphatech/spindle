(** Request methods. *)

type t =
  [ `GET
  | `HEAD
  | `POST
  | `PUT
  | `PATCH
  | `DELETE
  | `OPTIONS
  | `Other of string ]

val to_string : t -> string
val equal : t -> t -> bool
