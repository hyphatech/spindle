(* A page made with TyXML, written as HTML through its ppx: the markup is
   checked against the standard as it compiles, so a [p] inside a [ul] is a
   type error.

   Spindle has no template language: [Returns.html] answers the string a
   renderer made, so any renderer fits, and escaping what a person sent is
   the renderer's -- TyXML escapes text as it prints, so /hello/<b>kim</b> is
   words on the page. *)

open Spindle.Syntax
module Html = Tyxml.Html

let name = Spindle.Path.str "name"

let greeting name =
  let hello = "Hello, " ^ name ^ "!" in
  [%html
    {|<html lang="en">
        <head><title>Hello</title></head>
        <body><h1>|}
      [ Html.txt hello ]
      {|</h1></body>
      </html>|}]

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello" / name)
      Spindle.Returns.html
      (let+ name = Spindle.param name in
       Ok (Format.asprintf "%a" (Html.pp ()) (greeting name)));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
