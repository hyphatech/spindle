(* An application's command line, for test_cli to run: two routes, one of
   them read as opaque, so --strict has something to refuse. *)

open Spindle.Syntax

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
  ]

let () =
  Spindle_cli.run ~name:"shop" ~app:(fun _ ~sw:_ -> Spindle.App.make routes) ()
