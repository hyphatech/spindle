type t =
  [ `GET
  | `HEAD
  | `POST
  | `PUT
  | `PATCH
  | `DELETE
  | `OPTIONS
  | `Other of string ]

let to_string : t -> string = function
  | `GET -> "GET"
  | `HEAD -> "HEAD"
  | `POST -> "POST"
  | `PUT -> "PUT"
  | `PATCH -> "PATCH"
  | `DELETE -> "DELETE"
  | `OPTIONS -> "OPTIONS"
  | `Other m -> m

let equal a b = String.equal (to_string a) (to_string b)
