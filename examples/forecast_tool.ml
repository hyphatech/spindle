(* The tool mcp serves: the weather for a city. *)

open Spindle.Syntax

type query = { city : string } [@@deriving wiretype]
type forecast = { city : string; celsius : int } [@@deriving wiretype]

(* What the tool reads: something the server holds, supplied as it starts. *)
let weather : (string -> int option) Spindle.Dep.t =
  Spindle.Dep.of_resource "weather"

let no_such_city =
  Spindle.Refusal.Code.make "no_such_city" ~status:`Not_found
    ~doc:"No forecast for that city."

let get_forecast =
  Spindle_mcp.tool "get_forecast" ~title:"Forecast"
    ~doc:"Today's temperature in a city, in degrees Celsius." query_json
    forecast_json
    (let+ weather = weather in
     fun (q : query) ->
       match weather q.city with
       | Some celsius -> Ok { city = q.city; celsius }
       | None ->
           Error (Spindle.Refusal.make no_such_city "There is no such city."))
