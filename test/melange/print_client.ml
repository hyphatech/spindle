(* The client printed for the test application, which the suite compares with
   its committed copy. *)

let () =
  match
    Spindle.Melange.client
      ~header:
        "Printed by Spindle from test/melange/app.ml. Do not edit: run dune \
         promote."
      App.app
  with
  | Ok text -> print_string text
  | Error errors ->
      List.iter prerr_endline errors;
      exit 1
