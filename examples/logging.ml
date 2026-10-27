(* Logging: the levels and the format read from where the application keeps
   its settings, and a line of the application's own, which carries the id
   of the request that caused it.

     APP_LOG=debug dune exec examples/logging.exe
     curl localhost:8080/charge/500 *)

open Spindle.Syntax

let routes =
  List.map Spindle.Access.public
    [
      Spindle.get
        Spindle.Path.(s "charge" / Billing.pence)
        Spindle.Returns.text
        (let+ pence = Spindle.param Billing.pence in
         Billing.charge pence);
    ]

(* The framework reads no environment variable: the application hands it
   two strings, and either left unset is the default. *)
let () =
  match
    Spindle.Log.configure ~levels:(Sys.getenv_opt "APP_LOG")
      ~format:(Sys.getenv_opt "APP_LOG_FORMAT")
  with
  | Error why ->
      prerr_endline why;
      exit 1
  | Ok () -> Eio_main.run @@ fun env -> Spindle.serve env routes
