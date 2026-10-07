(* A cookie declared once, and used both to read it and to set it: the page
   counts your visits. *)

open Spindle.Syntax

let visits = Spindle.Cookie.named "visits" Spindle.Codec.int

let count seen set_cookie =
  let n = Option.value seen ~default:0 + 1 in
  set_cookie (Spindle.Cookie.make visits n);
  Ok (Printf.sprintf "Visit number %d." n)

let routes =
  [
    Spindle.get Spindle.Path.root Spindle.Returns.text
      (let+ seen = Spindle.Cookie.optional visits
       and+ set_cookie = Spindle.set_cookie in
       count seen set_cookie);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
