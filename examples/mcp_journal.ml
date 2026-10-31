(* An MCP server of resources: a journal an intent, offered as a template a
   client reads from a line on, and told to a client watching it as each line
   is written.

     curl -X POST localhost:8080/mcp \
       -H 'content-type: application/json' \
       -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: resources/read' \
       -H 'mcp-name: haf://intents/0197/journal?from=1' \
       -d '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{
             "uri":"haf://intents/0197/journal?from=1","_meta":{
             "io.modelcontextprotocol/protocolVersion":"2026-07-28",
             "io.modelcontextprotocol/clientCapabilities":{}}}}' *)

let id = "0197"
let uri = "haf://intents/" ^ id ^ "/journal"

(* A line a second, each told to whoever watches the journal. *)
let rec write ~clock journals changes n =
  Journal.append journals id (Printf.sprintf {|{"event":"tick","n":%d}|} n);
  Spindle_mcp.Changes.updated changes uri;
  Eio.Time.Mono.sleep_span clock Mtime.Span.(1 * s);
  write ~clock journals changes (n + 1)

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  let journals = Journal.create ()
  and changes = Spindle_mcp.Changes.create () in
  let routes =
    Spindle_mcp.routes ~name:"haf" ~version:"1.0.0"
      ~resources:[ Journal.journal ] ~changes []
  in
  (* A listen never ends on its own: a server that is stopping ends each,
     gracefully, so its client knows not to listen again. *)
  Eio.Fiber.first
    (fun () -> write ~clock:(Eio.Stdenv.mono_clock env) journals changes 1)
    (fun () ->
      Spindle.serve env
        ~resources:[ Spindle.Dep.resource Journal.journals journals ]
        ~on_stop:(fun () -> Spindle_mcp.Changes.close changes)
        routes)
