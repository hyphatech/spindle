(* A dependency of the application's own: a page of a list, read from two
   query parameters, which dependencies serves. *)

open Spindle.Syntax

type page = { page : int; per_page : int }

let too_small at =
  Spindle.Dep.problem ~at ~code:"too_small" "This is 1 or more."

(* Two query parameters read as one value, and checked: a number that is no
   page is a problem at its place, as a number that does not parse is. *)
let paging =
  Spindle.Dep.join
    (let+ page = Spindle.Query.optional "page" Spindle.Codec.int
     and+ per_page = Spindle.Query.optional "per_page" Spindle.Codec.int in
     let page = Option.value page ~default:1
     and per_page = Option.value per_page ~default:10 in
     if page < 1 then Error (too_small "query.page")
     else if per_page < 1 then Error (too_small "query.per_page")
     else Ok { page; per_page })
