(* Inputs, and a dependency of the application's own made of them: a page
   of a list, read from two query parameters, and refused at the one that
   is not a page's.

     curl 'localhost:8080/books?page=2&per_page=2'
     curl -i 'localhost:8080/books?page=0'
     curl -i 'localhost:8080/books?page=two' *)

open Spindle.Syntax

type page = { page : int; per_page : int }

(* --8<-- [start:paging] *)
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
(* --8<-- [end:paging] *)

let books = [ "Emma"; "Middlemarch"; "Persuasion"; "Ulysses"; "Walden" ]

let books_on { page; per_page } =
  Ok (List.filteri (fun i _ -> i / per_page = page - 1) books)

(* --8<-- [start:route] *)
let routes =
  [
    Spindle.get
      Spindle.Path.(s "books")
      (Spindle.Returns.json (Wiretype.list Wiretype.string))
      (let+ paging = paging in
       books_on paging);
  ]
(* --8<-- [end:route] *)

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
