(* An MCP server: one tool an agent calls, the weather for a city, added to
   the application's routes as health checks are. Point an MCP client at
   http://localhost:8080/mcp.

     curl -X POST localhost:8080/mcp \
       -H 'content-type: application/json' \
       -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: tools/list' \
       -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{
             "io.modelcontextprotocol/protocolVersion":"2026-07-28",
             "io.modelcontextprotocol/clientCapabilities":{}}}}' *)

let routes =
  Spindle_mcp.routes ~name:"weather" ~version:"1.0.0"
    [ Forecast_tool.get_forecast ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  let temperatures city = List.assoc_opt city [ ("Paris", 18); ("Oslo", 4) ] in
  Spindle.serve env
    ~resources:[ Spindle.Dep.resource Forecast_tool.weather temperatures ]
    routes
