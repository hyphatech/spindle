(* A part of the application with a log source of its own, whose line
   carries a field of the application's: logging serves it. *)

(* A source per part of the application, so its level can be set alone:
   APP_LOG=warn,shop.billing=debug. *)
module Log = (val Logs.src_log (Logs.Src.create "shop.billing") : Logs.LOG)

let pence = Spindle.Path.int "pence"

let charge pence =
  Log.info (fun m ->
      m "charged" ~tags:(Spindle.Log.tags [ ("shop.pence", `Int pence) ]));
  Ok "Charged."
