(* Inputs, and a dependency of the application's own made of them: a page
   of a list, read from two query parameters, and refused at the one that
   is not a page's.

     curl 'localhost:8080/books?page=2&per_page=2'
     curl -i 'localhost:8080/books?page=0'
     curl -i 'localhost:8080/books?page=two' *)

open Spindle.Syntax

let books = [ "Emma"; "Middlemarch"; "Persuasion"; "Ulysses"; "Walden" ]

let books_on { Paging.page; per_page } =
  Ok (List.filteri (fun i _ -> i / per_page = page - 1) books)

let routes =
  List.map Spindle.Access.public
    [
      Spindle.get
        Spindle.Path.(s "books")
        (Spindle.Returns.json (Wiretype.list Wiretype.string))
        (let+ paging = Paging.paging in
         books_on paging);
    ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
