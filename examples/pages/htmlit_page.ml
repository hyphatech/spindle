(* A page made with htmlit: combinators, and no dependency of their own.

   Spindle has no template language: [Returns.html] answers the string a
   renderer made, so any renderer fits, and escaping what a person sent is
   the renderer's -- [El.txt] escapes, so /hello/<b>kim</b> is words on the
   page. *)

open Spindle.Syntax
module El = Htmlit.El

let name = Spindle.Path.str "name"

let greeting name =
  El.page ~lang:"en" ~title:"Hello"
    (El.body [ El.h1 [ El.txt ("Hello, " ^ name ^ "!") ] ])

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello" / name)
      Spindle.Returns.html
      (let+ name = Spindle.param name in
       Ok (El.to_string ~doctype:true (greeting name)));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
