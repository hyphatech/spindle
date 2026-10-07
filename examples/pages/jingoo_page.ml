(* A page made with jingoo, from a template file in Jinja's syntax:
   templates/greeting.jingoo, read once when the program starts and rendered
   for every request. Run it from the repository's root, as every example
   is.

   Spindle has no template language: [Returns.html] answers the string a
   renderer made, so any renderer fits, and escaping what a person sent is
   the renderer's -- jingoo escapes every value it writes unless told not
   to, so /hello/<b>kim</b> is words on the page. *)

open Spindle.Syntax
module Jg_template = Jingoo.Jg_template
module Jg_types = Jingoo.Jg_types

let name = Spindle.Path.str "name"

let greeting =
  Jg_template.Loaded.from_file "examples/pages/templates/greeting.jingoo"

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello" / name)
      Spindle.Returns.html
      (let+ name = Spindle.param name in
       Ok
         (Jg_template.Loaded.eval greeting
            ~models:[ ("name", Jg_types.Tstr name) ]));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
