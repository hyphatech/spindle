(* An MCP server: one tool an agent calls, the weather for a city, added to
   the application's routes as health checks are. Point an MCP client at
   http://localhost:8080/mcp.

     curl -X POST localhost:8080/mcp \
       -H 'content-type: application/json' \
       -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: tools/list' \
       -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{
             "io.modelcontextprotocol/protocolVersion":"2026-07-28",
             "io.modelcontextprotocol/clientCapabilities":{}}}}' *)

open Spindle.Syntax

(* --8<-- [start:tool] *)
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
(* --8<-- [end:tool] *)

(* --8<-- [start:serve] *)
let routes =
  Spindle_mcp.routes ~name:"weather" ~version:"1.0.0" [ get_forecast ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  let temperatures city = List.assoc_opt city [ ("Paris", 18); ("Oslo", 4) ] in
  Spindle.serve env
    ~resources:[ Spindle.Dep.resource weather temperatures ]
    routes
(* --8<-- [end:serve] *)
