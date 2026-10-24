(* Calling another server's tools: the weather server of mcp.ml, run
   beside this one. It links spindle-client and no framework.

     dune exec examples/mcp.exe &
     dune exec examples/mcp_client.exe *)

type query = { city : string } [@@deriving wiretype]
type forecast = { city : string; celsius : int } [@@deriving wiretype]

let () =
  Eio_main.run @@ fun env ->
  Spindle_client.run env @@ fun client ->
  let weather =
    Spindle_mcp_client.create client ~url:"http://localhost:8080/mcp"
  in
  match Spindle_mcp_client.tools weather with
  | Error e -> prerr_endline (Spindle_mcp_client.error_to_string e)
  | Ok tools -> (
      List.iter
        (fun (t : Spindle_mcp_client.tool) -> print_endline t.name)
        tools;
      match
        Spindle_mcp_client.call weather "get_forecast" query_json
          { city = "Paris" } forecast_json
      with
      | Ok f -> Printf.printf "%s: %d°C\n" f.city f.celsius
      | Error e -> prerr_endline (Spindle_mcp_client.error_to_string e))
