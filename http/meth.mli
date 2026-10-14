(** Request methods: every one RFC 9110 §9 defines, and [PATCH] (RFC 5789);
    [`Other m] is any other, spelled as it came.

    {b The set is closed at 1.0.} A method registered later stays [`Other m] for
    every 1.x release, so a match on this type keeps its meaning across them. *)

type t =
  [ `GET
  | `HEAD
  | `POST
  | `PUT
  | `PATCH
  | `DELETE
  | `OPTIONS
  | `CONNECT
  | `TRACE
  | `Other of string ]

val to_string : t -> string
val equal : t -> t -> bool
