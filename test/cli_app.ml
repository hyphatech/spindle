(* An application's command line, for test_cli to run: three routes, one of
   them read as opaque, so --strict has something to refuse, and one reading
   a resource nothing supplies, since a description needs none. *)

open Spindle.Syntax

let database : string Spindle.Dep.t = Spindle.Dep.of_resource "database"

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello")
      Spindle.Returns.text
      (Spindle.Dep.return (Ok "Good morning."));
    Spindle.get
      Spindle.Path.(s "anything")
      Spindle.Returns.response
      (let+ _ = Spindle.request in
       Ok (Spindle.Response.make ""));
    Spindle.get
      Spindle.Path.(s "notes")
      Spindle.Returns.text
      (let+ db = database in
       Ok db);
  ]

let () = Spindle_cli.run ~name:"shop" ~app:(Spindle.App.make routes) ()
