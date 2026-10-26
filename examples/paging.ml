(* A dependency of the application's own: a page of a list, read from two
   query parameters, which dependencies serves. *)

open Spindle.Syntax

type page = { page : int; per_page : int }

(* Two query parameters read as one value, each by the description a body's
   member would be: a number outside its bounds is a problem at its place,
   as a number that does not parse is, and the document says both bounds. *)
let paging =
  let+ page = Spindle.Query.default "page" (Wiretype.int_bounded ~min:1 ()) 1
  and+ per_page =
    Spindle.Query.default "per_page"
      (Wiretype.int_bounded ~min:1 ~max:100 ())
      10
  in
  { page; per_page }
