(* Logging: the levels and the format read from where the application keeps
   its settings, and a line of the application's own, which carries the id
   of the request that caused it.

     APP_LOG=debug dune exec examples/logging.exe
     curl localhost:8080/charge/500 *)

open Spindle.Syntax

(* --8<-- [start:line] *)
(* A source per part of the application, so its level can be set alone:
   APP_LOG=warn,shop.billing=debug. *)
module Log = (val Logs.src_log (Logs.Src.create "shop.billing") : Logs.LOG)

let pence = Spindle.Path.int "pence"

let charge pence =
  Log.info (fun m ->
      m "charged" ~tags:(Spindle.Log.tags [ ("shop.pence", `Int pence) ]));
  Ok "Charged."
(* --8<-- [end:line] *)

let routes =
  [
    Spindle.get
      Spindle.Path.(s "charge" / pence)
      Spindle.Returns.text
      (let+ pence = Spindle.param pence in
       charge pence);
  ]

(* --8<-- [start:setup] *)
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
(* --8<-- [end:setup] *)
