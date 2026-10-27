(* A program that serves and does nothing else, for test_spindle to run as a
   process on the port it is given: what [Spindle.serve] says, and its exit
   status, where it cannot listen. It sets no log up, as the smallest
   program does not. *)

let () =
  match Array.to_list Sys.argv with
  | [ _; port ] -> (
      match int_of_string_opt port with
      | Some port ->
          Eio_main.run @@ fun env ->
          Spindle.serve env ~host:"127.0.0.1" ~port
            [
              Spindle.get Spindle.Path.root Spindle.Returns.text
                (Spindle.Dep.return (Ok "a"));
            ]
      | None -> exit 2)
  | _ -> exit 2
