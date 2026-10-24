(* MCP 2026-07-28 as Spindle's server speaks it, a row a requirement, named
   by the specification's page and section: the base protocol, the Streamable
   HTTP transport, versioning, discovery and tools. *)

module Mcp = Spindle_mcp
module Value = Wiretype.Value
open Spindle.Syntax

let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

(* ------------------------------------------------------------------ *)
(* A server with three tools *)

type query = { city : string }

let query_json =
  Wiretype.Object.(
    map (fun city -> { city })
    |> mem "city" Wiretype.string ~enc:(fun q -> q.city)
    |> finish)

type forecast = { place : string; celsius : int }

let forecast_json =
  Wiretype.Object.(
    map ~kind:"forecast" (fun place celsius -> { place; celsius })
    |> mem "place" Wiretype.string ~enc:(fun f -> f.place)
    |> mem "celsius" Wiretype.int ~enc:(fun f -> f.celsius)
    |> finish)

(* What the tools read: a resource the server holds, as a pool would be. *)
let weather : (string -> int option) Spindle.Dep.t =
  Spindle.Dep.of_resource "weather"

let no_such_city =
  Spindle.Refusal.Code.make "no_such_city" ~status:`Not_found
    ~doc:"No forecast for that city."

let get_forecast =
  Mcp.tool "get_forecast" ~title:"Forecast" ~doc:"Today's weather for a city."
    query_json forecast_json
    (let+ weather = weather in
     fun q ->
       match weather q.city with
       | Some celsius -> Ok { place = q.city; celsius }
       | None ->
           Error (Spindle.Refusal.make no_such_city "There is no such city."))

let echo =
  Mcp.tool "echo" query_json Wiretype.string
    (Spindle.Dep.return (fun q -> Ok q.city))

let tools = [ get_forecast; echo ]
let temperatures city = List.assoc_opt city [ ("Paris", 18) ]

let app ?(tools = tools) () =
  Spindle.Test.app
    ~resources:[ Spindle.Dep.resource weather temperatures ]
    (Mcp.routes ~name:"weather" ~version:"1.0.0" tools)

let call ?headers ?capabilities meth params =
  Mcp.Test.call ?headers ?capabilities (app ()) meth params

let json (r : Spindle.Test.response) =
  match Yojson.Safe.from_string r.body with
  | j -> j
  | exception Yojson.Json_error e -> Alcotest.failf "no JSON (%s): %S" e r.body

let at path j = List.fold_left (fun j k -> Yojson.Safe.Util.member k j) j path
let text path r = Yojson.Safe.to_string (at path (json r))

let check_status name expected (r : Spindle.Test.response) =
  check_int name expected (Spindle.Status.to_int r.status)

let check_error name ~status ~code r =
  check_status name status r;
  check_string (name ^ ", its code") (string_of_int code)
    (text [ "error"; "code" ] r)

(* The raw POST a client that gets something wrong sends. *)
let post ?(headers = []) body =
  Spindle.Test.call
    ~headers:([ ("content-type", "application/json") ] @ headers)
    ~body (app ()) `POST "/mcp"

let well_formed_headers meth =
  [ ("mcp-protocol-version", "2026-07-28"); ("mcp-method", meth) ]

let meta =
  {|"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}|}

(* ------------------------------------------------------------------ *)
(* The base protocol *)

(* basic §Messages: a body that is no JSON is a parse error, and one that is
   no request -- a batch, which MCP has none of, a null id, a response, no
   jsonrpc -- an invalid request; both 400. *)
let test_a_message_is_one_request () =
  check_error "no JSON" ~status:400 ~code:(-32700)
    (post ~headers:(well_formed_headers "tools/list") "{not json");
  List.iter
    (fun (name, body) ->
      check_error name ~status:400 ~code:(-32600)
        (post ~headers:(well_formed_headers "tools/list") body))
    [
      ( "a batch",
        Printf.sprintf
          {|[{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{%s}}]|}
          meta );
      ( "a null id",
        Printf.sprintf
          {|{"jsonrpc":"2.0","id":null,"method":"tools/list","params":{%s}}|}
          meta );
      ("a response", {|{"jsonrpc":"2.0","id":1,"result":{}}|});
      ( "no jsonrpc",
        Printf.sprintf {|{"id":1,"method":"tools/list","params":{%s}}|} meta );
      ( "jsonrpc 1.0",
        Printf.sprintf
          {|{"jsonrpc":"1.0","id":1,"method":"tools/list","params":{%s}}|} meta
      );
    ]

(* basic §_meta: a request without its version and its capabilities is
   malformed, -32602, 400. *)
let test_a_request_carries_its_version_and_capabilities () =
  check_error "no capabilities" ~status:400 ~code:(-32602)
    (post
       ~headers:(well_formed_headers "tools/list")
       {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}|});
  check_error "no _meta" ~status:400 ~code:(-32602)
    (post
       ~headers:(well_formed_headers "tools/list")
       {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}|})

(* basic §Responses: every result says it is complete, and names the
   server. *)
let test_every_result_is_complete_and_names_the_server () =
  List.iter
    (fun (meth, params) ->
      let r = call meth params in
      check_status meth 200 r;
      check_string (meth ^ ", its id") "1" (text [ "id" ] r);
      check_string (meth ^ ", resultType") {|"complete"|}
        (text [ "result"; "resultType" ] r);
      check_string (meth ^ ", serverInfo")
        {|{"name":"weather","version":"1.0.0"}|}
        (text [ "result"; "_meta"; "io.modelcontextprotocol/serverInfo" ] r))
    [
      ("server/discover", []);
      ("tools/list", []);
      ( "tools/call",
        [
          ("name", Value.String "echo");
          ("arguments", Value.Object [ ("city", Value.String "Paris") ]);
        ] );
    ]

(* ------------------------------------------------------------------ *)
(* The Streamable HTTP transport *)

(* streamable-http §Sending Messages: a notification is accepted with 202
   and no body. *)
let test_a_notification_is_202 () =
  let r =
    post
      ~headers:(well_formed_headers "notifications/cancelled")
      {|{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}|}
  in
  check_status "202" 202 r;
  check_string "no body" "" r.body

(* streamable-http §Protocol Version Header: a method the server does not
   implement is 404 with -32601. *)
let test_a_method_not_served_is_404 () =
  check_error "resources/list" ~status:404 ~code:(-32601)
    (call "resources/list" [])

(* streamable-http §Server Validation: the headers that mirror the body
   must be there and agree with it, or 400 -32020. *)
let test_the_headers_agree_with_the_body () =
  let body =
    Printf.sprintf
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"city":"Paris"},%s}}|}
      meta
  in
  let with_headers h = post ~headers:h body in
  check_status "all agree" 200
    (with_headers (well_formed_headers "tools/call" @ [ ("mcp-name", "echo") ]));
  List.iter
    (fun (name, h) ->
      check_error name ~status:400 ~code:(-32020) (with_headers h))
    [
      ( "no MCP-Protocol-Version",
        [ ("mcp-method", "tools/call"); ("mcp-name", "echo") ] );
      ( "no Mcp-Method",
        [ ("mcp-protocol-version", "2026-07-28"); ("mcp-name", "echo") ] );
      ("no Mcp-Name", well_formed_headers "tools/call");
      ( "another method",
        well_formed_headers "tools/list" @ [ ("mcp-name", "echo") ] );
      ( "another name",
        well_formed_headers "tools/call" @ [ ("mcp-name", "get_forecast") ] );
    ]

(* streamable-http §Value Encoding: a name sent in the Base64 sentinel form
   is read decoded before it is compared. *)
let test_a_name_in_base64_is_decoded () =
  let body =
    Printf.sprintf
      {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"city":"Paris"},%s}}|}
      meta
  in
  check_status "=?base64?ZWNobw==?=" 200
    (post
       ~headers:
         (well_formed_headers "tools/call"
         @ [ ("mcp-name", "=?base64?ZWNobw==?=") ])
       body)

(* streamable-http §Security: an Origin of another site is refused 403,
   against DNS rebinding. *)
let test_another_sites_origin_is_refused () =
  check_status "403" 403
    (call
       ~headers:
         [
           ("origin", "https://evil.example"); ("sec-fetch-site", "cross-site");
         ]
       "tools/list" [])

(* streamable-http §Backward Compatibility: GET at the endpoint is 405, as a
   server speaking 2026-07-28 alone answers. *)
let test_get_is_405 () =
  check_status "GET" 405 (Spindle.Test.call (app ()) `GET "/mcp")

(* ------------------------------------------------------------------ *)
(* Versioning and discovery *)

(* versioning §Protocol Version Negotiation: another version is 400 -32022,
   naming the one supported. *)
let test_another_version_is_unsupported () =
  let body =
    {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-11-25","io.modelcontextprotocol/clientCapabilities":{}}}}|}
  in
  let r =
    post
      ~headers:
        [ ("mcp-protocol-version", "2025-11-25"); ("mcp-method", "tools/list") ]
      body
  in
  check_error "400" ~status:400 ~code:(-32022) r;
  check_string "supported" {|["2026-07-28"]|}
    (text [ "error"; "data"; "supported" ] r);
  check_string "requested" {|"2025-11-25"|}
    (text [ "error"; "data"; "requested" ] r)

(* versioning §Backward Compatibility: a legacy client's initialize, which
   names its version in its params and has no header to mirror it, is
   answered with the version this server speaks, the one thing such a client
   can show its user. *)
let test_initialize_names_the_supported_version () =
  let r =
    post
      {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"old","version":"1"}}}|}
  in
  check_error "400" ~status:400 ~code:(-32022) r;
  check_string "supported" {|["2026-07-28"]|}
    (text [ "error"; "data"; "supported" ] r);
  check_string "requested" {|"2025-11-25"|}
    (text [ "error"; "data"; "requested" ] r)

(* server/discover: the versions, the capabilities, and the caching hints
   every discovery carries. *)
let test_discover () =
  let r = call "server/discover" [] in
  check_string "supportedVersions" {|["2026-07-28"]|}
    (text [ "result"; "supportedVersions" ] r);
  check_string "capabilities" {|{"tools":{}}|}
    (text [ "result"; "capabilities" ] r);
  check_string "ttlMs" "300000" (text [ "result"; "ttlMs" ] r);
  check_string "cacheScope" {|"public"|} (text [ "result"; "cacheScope" ] r)

(* ------------------------------------------------------------------ *)
(* Tools *)

(* tools §Listing Tools: every tool, in the order given, its schemas printed
   from its descriptions, the input an object; caching hints. *)
let test_tools_are_listed_with_their_schemas () =
  let r = call "tools/list" [] in
  let tools = at [ "result"; "tools" ] (json r) in
  check_string "names, in order" {|["get_forecast","echo"]|}
    (Yojson.Safe.to_string
       (`List
          (List.map (fun t -> at [ "name" ] t) (Yojson.Safe.Util.to_list tools))));
  let first =
    match Yojson.Safe.Util.to_list tools with
    | t :: _ -> t
    | [] -> Alcotest.fail "no tools"
  in
  check_string "title" {|"Forecast"|}
    (Yojson.Safe.to_string (at [ "title" ] first));
  check_string "description" {|"Today's weather for a city."|}
    (Yojson.Safe.to_string (at [ "description" ] first));
  check_string "inputSchema is an object" {|"object"|}
    (Yojson.Safe.to_string (at [ "inputSchema"; "type" ] first));
  check_string "its member" {|"string"|}
    (Yojson.Safe.to_string
       (at [ "inputSchema"; "properties"; "city"; "type" ] first));
  check_string "outputSchema" {|"object"|}
    (Yojson.Safe.to_string (at [ "outputSchema"; "type" ] first));
  check_string "ttlMs" "300000" (text [ "result"; "ttlMs" ] r);
  check_string "cacheScope" {|"public"|} (text [ "result"; "cacheScope" ] r);
  check_string "no cursor" "null" (text [ "result"; "nextCursor" ] r)

let tools_call name arguments =
  call "tools/call" [ ("name", Value.String name); ("arguments", arguments) ]

let paris = Value.Object [ ("city", Value.String "Paris") ]

(* tools §Structured Content: the result as structuredContent, and its JSON
   as text beside it. *)
let test_a_call_answers_its_structured_result () =
  let r = tools_call "get_forecast" paris in
  check_status "200" 200 r;
  check_string "structuredContent" {|{"place":"Paris","celsius":18}|}
    (text [ "result"; "structuredContent" ] r);
  check_string "its text"
    {|[{"type":"text","text":"{\"place\":\"Paris\",\"celsius\":18}"}]|}
    (text [ "result"; "content" ] r);
  check_string "isError" "false" (text [ "result"; "isError" ] r)

(* tools §Error Handling: arguments that do not read, and a tool's own
   failure, are tool execution errors the model reads -- not protocol
   errors. *)
let test_a_tools_failure_is_a_result () =
  let r =
    tools_call "get_forecast" (Value.Object [ ("town", Value.String "Paris") ])
  in
  check_status "unreadable arguments, 200" 200 r;
  check_string "isError" "true" (text [ "result"; "isError" ] r);
  let r =
    tools_call "get_forecast"
      (Value.Object [ ("city", Value.String "Atlantis") ])
  in
  check_string "a tool's Error, isError" "true" (text [ "result"; "isError" ] r);
  check_string "its sentence"
    {|[{"type":"text","text":"There is no such city."}]|}
    (text [ "result"; "content" ] r)

(* tools §Error Handling: an unknown tool is a protocol error, -32602. *)
let test_an_unknown_tool_is_invalid_params () =
  let r = tools_call "nothing" paris in
  check_string "-32602" "-32602" (text [ "error"; "code" ] r)

(* What every tool reads is the route's: a resource a tool reads is checked
   as the server starts. *)
let test_a_tools_resource_is_checked_at_start () =
  match Spindle.App.make (Mcp.routes ~name:"w" ~version:"1" tools) with
  | Error e -> Alcotest.fail e
  | Ok a ->
      check_bool "refused without it" true
        (match
           Spindle.App.start a ~mono_clock:(Eio_mock.Clock.Mono.make ())
         with
        | Error _ -> true
        | Ok _ -> false)

(* What routes refuses, each a constant written in source. *)
let test_routes_refuses_what_cannot_be_served () =
  let refused name tools ?auth () =
    check_bool name true
      (match Mcp.routes ?auth ~name:"w" ~version:"1" tools with
      | _ -> false
      | exception Invalid_argument _ -> true)
  in
  refused "two tools of one name" [ echo; echo ] ();
  refused "a name with a space"
    [
      Mcp.tool "get forecast" query_json Wiretype.string
        (Spindle.Dep.return (fun _ -> Ok ""));
    ]
    ();
  refused "arguments that are no object"
    [
      Mcp.tool "n" Wiretype.string Wiretype.string
        (Spindle.Dep.return (fun s -> Ok s));
    ]
    ();
  refused "a scope with no auth"
    [
      Mcp.tool "s" ~scope:"x" query_json Wiretype.string
        (Spindle.Dep.return (fun _ -> Ok ""));
    ]
    ();
  refused "a dependency that may refuse"
    [
      Mcp.tool "r" query_json Wiretype.string
        (Spindle.Dep.join ~refuses:[ no_such_city ]
           (Spindle.Dep.return (Ok (fun _ -> Ok ""))));
    ]
    ()

(* ------------------------------------------------------------------ *)
(* A bearer token *)

let ed_priv, ed_pub =
  Mirage_crypto_rng_unix.use_default ();
  Mirage_crypto_ec.Ed25519.generate ()

let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let key =
  match
    Spindle_http.Jwk.of_string
      (Printf.sprintf {|{"kty":"OKP","crv":"Ed25519","x":"%s"}|}
         (b64 (Mirage_crypto_ec.Ed25519.pub_to_octets ed_pub)))
  with
  | Ok k -> k
  | Error e -> Alcotest.fail e

let issuer = "https://id.example.com"
let resource = "https://api.example.com/mcp"
let auth = Spindle.Bearer.make ~issuer ~resource
let now = Ptime.of_float_s 1792756800. |> Option.value ~default:Ptime.epoch

let token scope =
  let at s = Printf.sprintf "%.0f" (Ptime.to_float_s now +. s) in
  let payload =
    Printf.sprintf
      {|{"iss":%S,"aud":%S,"sub":"ada","client_id":"c","iat":%s,"exp":%s,"jti":"t","scope":%S}|}
      issuer resource (at (-60.)) (at 300.) scope
  in
  let input = b64 {|{"alg":"EdDSA","typ":"at+jwt"}|} ^ "." ^ b64 payload in
  input ^ "." ^ b64 (Mirage_crypto_ec.Ed25519.sign ~key:ed_priv input)

let scoped =
  Mcp.tool "get_forecast" ~scope:"weather:read" query_json forecast_json
    (let+ weather = weather in
     fun q ->
       Option.to_result
         ~none:(Spindle.Refusal.make no_such_city "There is no such city.")
         (Option.map
            (fun celsius -> { place = q.city; celsius })
            (weather q.city)))

let authed_routes =
  Mcp.routes ~auth ~name:"weather" ~version:"1.0.0" [ scoped; echo ]

let authed () =
  Spindle.Test.app
    ~resources:
      [
        Spindle.Dep.resource weather temperatures;
        Spindle.Dep.resource (Spindle.Bearer.keys auth) (fun ~kid:_ -> [ key ]);
      ]
    (authed_routes @ [ Spindle.Bearer.metadata auth authed_routes ])

let authed_call ?token:t meth params =
  let headers =
    match t with Some t -> [ ("authorization", "Bearer " ^ t) ] | None -> []
  in
  Mcp.Test.call ~now ~headers (authed ()) meth params

(* authorization §Access Token Usage: every request carries a token. *)
let test_a_call_without_a_token_is_401 () =
  check_status "401" 401 (authed_call "tools/list" [])

(* tools §Capabilities: the list is the token's -- a tool whose scope it does
   not grant is left out -- and private to it. *)
let test_the_list_is_the_tokens () =
  let names t =
    let r = authed_call ~token:(token t) "tools/list" [] in
    Yojson.Safe.to_string
      (`List
         (List.map
            (fun t -> at [ "name" ] t)
            (Yojson.Safe.Util.to_list (at [ "result"; "tools" ] (json r)))))
  in
  check_string "with the scope" {|["get_forecast","echo"]|}
    (names "weather:read");
  check_string "without it" {|["echo"]|} (names "profile");
  check_string "cacheScope" {|"private"|}
    (text [ "result"; "cacheScope" ]
       (authed_call ~token:(token "profile") "tools/list" []))

(* authorization §Scope Challenge Handling: a call of a tool whose scope the
   token lacks is 403 insufficient_scope, naming the scope. *)
let test_a_scope_not_granted_is_403 () =
  let r =
    authed_call ~token:(token "profile") "tools/call"
      [ ("name", Value.String "get_forecast"); ("arguments", paris) ]
  in
  check_status "403" 403 r;
  check_bool "the challenge names it" true
    (match Spindle.Test.header r "www-authenticate" with
    | Some c ->
        String.length c > 0
        && Option.is_some
             (List.find_opt
                (String.equal {|scope="weather:read"|})
                (List.map String.trim (String.split_on_char ',' c)))
    | None -> false);
  check_status "granted" 200
    (authed_call ~token:(token "weather:read") "tools/call"
       [ ("name", Value.String "get_forecast"); ("arguments", paris) ])

(* RFC 9728 §2: the metadata names every tool's scope. *)
let test_the_metadata_names_every_tools_scope () =
  let r =
    Spindle.Test.call (authed ()) `GET
      "/.well-known/oauth-protected-resource/mcp"
  in
  check_string "scopes_supported" {|["weather:read"]|}
    (text [ "scopes_supported" ] r)

(* ------------------------------------------------------------------ *)
(* The client *)

module Client = Spindle_mcp_client

(* A Spindle server on a socket of its own, and a client to call it. *)
let over_a_socket ?(routes = Mcp.routes ~name:"weather" ~version:"1.0.0" tools)
    f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains:1
        ~read_clock:(fun () -> Ptime.epoch)
        ~limits:(Spindle.Server.Limits.make ~drain:Mtime.Span.(100 * ms) ())
        [ socket ]
        (Spindle.Test.app
           ~resources:[ Spindle.Dep.resource weather temperatures ]
           routes);
      `Stop_daemon);
  Spindle_client.run env @@ fun client ->
  f (Client.create client ~url:(Printf.sprintf "http://127.0.0.1:%d/mcp" port))

(* A stub server answering as the test says, and what it was asked. *)
let against respond f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let asked = ref [] in
  let port =
    Stub_server.serve ~sw ~net:(Eio.Stdenv.net env) (fun r ->
        asked := r :: !asked;
        respond r)
  in
  Spindle_client.run env @@ fun client ->
  f ~client ~url:(Printf.sprintf "http://127.0.0.1:%d/mcp" port)
    ~asked:(fun () -> List.rev !asked)

let ok = function
  | Ok v -> v
  | Error e -> Alcotest.failf "the client: %s" (Client.error_to_string e)

let body_json (r : Stub_server.request) = Yojson.Safe.from_string r.body

let answer ?(content_type = "application/json") body =
  Stub_server.reply ~headers:[ ("content-type", content_type) ] `OK body

let result id members =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete",%s}}|} id
    members

let id_of r = Yojson.Safe.to_string (at [ "id" ] (body_json r))

(* Scenario 5: our client lists and calls our server's tools, typed. *)
let test_our_client_calls_our_server () =
  over_a_socket @@ fun c ->
  let s = ok (Client.discover c) in
  check_string "a version" "2026-07-28" (String.concat "," s.versions);
  check_string "its name" "weather" (Option.value ~default:"" s.name);
  let tools = ok (Client.tools c) in
  check_string "its tools" "get_forecast,echo"
    (String.concat "," (List.map (fun (t : Client.tool) -> t.name) tools));
  let f =
    ok
      (Client.call c "get_forecast" query_json { city = "Paris" } forecast_json)
  in
  check_int "the forecast" 18 f.celsius

(* tools §Error Handling: a tool's failure is its own, not a refusal. *)
let test_a_tools_failure_reaches_the_caller () =
  over_a_socket @@ fun c ->
  match
    Client.call c "get_forecast" query_json { city = "Atlantis" } forecast_json
  with
  | Error (`Tool_failed why) ->
      check_string "its sentence" "There is no such city." why
  | Ok _ -> Alcotest.fail "answered"
  | Error e -> Alcotest.failf "another failure: %s" (Client.error_to_string e)

(* A protocol error is the server's refusal, its code kept. *)
let test_a_protocol_error_is_a_refusal () =
  over_a_socket @@ fun c ->
  match Client.call_value c "nothing" (Value.Object []) with
  | Error (`Refused (r : Client.refusal)) ->
      check_bool "-32602" true (Option.equal Int.equal r.code (Some (-32602)))
  | Ok _ -> Alcotest.fail "answered"
  | Error e -> Alcotest.failf "another failure: %s" (Client.error_to_string e)

(* streamable-http §Sending Messages and §Request Metadata: every request is
   a POST taking both answers, its headers and its _meta the revision's. *)
let test_every_request_carries_what_the_revision_asks () =
  against
    (fun r ->
      answer
        (result (id_of r)
           {|"content":[{"type":"text","text":"ok"}],"structuredContent":"ok"|}))
    (fun ~client ~url ~asked ->
      let c = Client.create ~name:"tester" ~version:"2" client ~url in
      let (_ : Client.answer) =
        ok (Client.call_value c "echo" (Value.Object []))
      in
      match asked () with
      | [ r ] ->
          check_bool "POST" true
            (match r.meth with `POST -> true | _ -> false);
          let h n = Option.value ~default:"" (Stub_server.header r n) in
          check_string "accept" "application/json, text/event-stream"
            (h "accept");
          check_string "MCP-Protocol-Version" "2026-07-28"
            (h "mcp-protocol-version");
          check_string "Mcp-Method" "tools/call" (h "mcp-method");
          check_string "Mcp-Name" "echo" (h "mcp-name");
          let meta = at [ "params"; "_meta" ] (body_json r) in
          check_string "_meta's version" {|"2026-07-28"|}
            (Yojson.Safe.to_string
               (at [ "io.modelcontextprotocol/protocolVersion" ] meta));
          check_string "capabilities, none" "{}"
            (Yojson.Safe.to_string
               (at [ "io.modelcontextprotocol/clientCapabilities" ] meta));
          check_string "clientInfo" {|{"name":"tester","version":"2"}|}
            (Yojson.Safe.to_string
               (at [ "io.modelcontextprotocol/clientInfo" ] meta))
      | _ -> Alcotest.fail "not one request")

(* streamable-http §Value Encoding: a name that is no plain ASCII is sent in
   the Base64 sentinel form. *)
let test_a_name_not_plain_ascii_is_sent_in_base64 () =
  against
    (fun r -> answer (result (id_of r) {|"content":[]|}))
    (fun ~client ~url ~asked ->
      let c = Client.create client ~url in
      let (_ : Client.answer) =
        ok (Client.call_value c "café" (Value.Object []))
      in
      match asked () with
      | [ r ] ->
          check_string "Mcp-Name"
            ("=?base64?" ^ Base64.encode_string "café" ^ "?=")
            (Option.value ~default:"" (Stub_server.header r "mcp-name"))
      | _ -> Alcotest.fail "not one request")

(* streamable-http §Sending Messages: the client reads an answer sent as an
   event stream, notifications before the response. *)
let test_an_answer_as_an_event_stream_is_read () =
  against
    (fun r ->
      answer ~content_type:"text/event-stream"
        ("event: message\n\
          data: \
          {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}\n\n"
       ^ "event: message\ndata: "
        ^ result (id_of r) {|"content":[{"type":"text","text":"done"}]|}
        ^ "\n\n"))
    (fun ~client ~url ~asked:_ ->
      let a =
        ok
          (Client.call_value
             (Client.create client ~url)
             "slow" (Value.Object []))
      in
      check_int "its content" 1 (List.length a.content))

let x_tool annotation_type value =
  Printf.sprintf
    {|{"name":"sql","inputSchema":{"type":"object","properties":{"region":{"type":"%s","x-mcp-header":"Region"},"query":{"type":"string"}}},"x":%s}|}
    annotation_type value

(* tools §x-mcp-header and streamable-http §Custom Headers: an annotated
   argument is mirrored as Mcp-Param-, plain or in Base64, and left out
   where it has no value. *)
let test_annotated_arguments_are_mirrored () =
  against
    (fun r ->
      match Yojson.Safe.to_string (at [ "method" ] (body_json r)) with
      | {|"tools/list"|} ->
          answer
            (result (id_of r)
               (Printf.sprintf {|"tools":[%s],"ttlMs":0,"cacheScope":"public"|}
                  (x_tool "string" "0")))
      | _ -> answer (result (id_of r) {|"content":[]|}))
    (fun ~client ~url ~asked ->
      let c = Client.create client ~url in
      (* An agent lists before it calls, and the list says what to mirror. *)
      let (_ : Client.tool list) = ok (Client.tools c) in
      let call region =
        let args =
          Value.Object
            ((match region with
               | Some v -> [ ("region", Value.String v) ]
               | None -> [])
            @ [ ("query", Value.String "select 1") ])
        in
        let (_ : Client.answer) = ok (Client.call_value c "sql" args) in
        let calls =
          List.filter
            (fun r ->
              String.equal
                (Yojson.Safe.to_string (at [ "method" ] (body_json r)))
                {|"tools/call"|})
            (asked ())
        in
        match List.rev calls with
        | r :: _ -> Stub_server.header r "mcp-param-region"
        | [] -> Alcotest.fail "no call"
      in
      check_string "plain" "us-west1"
        (Option.value ~default:"" (call (Some "us-west1")));
      check_string "Base64"
        ("=?base64?" ^ Base64.encode_string "Zürich" ^ "?=")
        (Option.value ~default:"" (call (Some "Zürich")));
      check_bool "absent" true (Option.is_none (call None)))

(* tools §x-mcp-header: a tool whose annotation breaks the rules -- on a
   number, under an array -- is left out of the list. *)
let test_a_tool_with_a_bad_annotation_is_left_out () =
  against
    (fun r ->
      answer
        (result (id_of r)
           (Printf.sprintf
              {|"tools":[%s,%s,%s],"ttlMs":0,"cacheScope":"public"|}
              (x_tool "number" "1")
              {|{"name":"items","inputSchema":{"type":"object","properties":{"rows":{"type":"array","items":{"type":"string","x-mcp-header":"Row"}}}}}|}
              {|{"name":"good","inputSchema":{"type":"object"}}|})))
    (fun ~client ~url ~asked:_ ->
      let tools = ok (Client.tools (Client.create client ~url)) in
      check_string "only the good one" "good"
        (String.concat "," (List.map (fun (t : Client.tool) -> t.name) tools)))

(* pagination: every page is read, in order. *)
let test_every_page_is_read () =
  against
    (fun r ->
      match at [ "params"; "cursor" ] (body_json r) with
      | `Null ->
          answer
            (result (id_of r)
               {|"tools":[{"name":"a","inputSchema":{"type":"object"}}],"nextCursor":"2","ttlMs":0,"cacheScope":"public"|})
      | _ ->
          answer
            (result (id_of r)
               {|"tools":[{"name":"b","inputSchema":{"type":"object"}}],"ttlMs":0,"cacheScope":"public"|}))
    (fun ~client ~url ~asked:_ ->
      let tools = ok (Client.tools (Client.create client ~url)) in
      check_string "both pages" "a,b"
        (String.concat "," (List.map (fun (t : Client.tool) -> t.name) tools)))

let asks =
  {|"resultType":"input_required","inputRequests":{"confirm":{"method":"elicitation/create","params":{"mode":"form","message":"Sure?","requestedSchema":{"type":"object","properties":{"ok":{"type":"boolean"}}}}}},"requestState":"opaque-7"|}

(* mrtr §Client Requirements: a question is answered through elicit and the
   call retried as a new request, its answers and the state echoed. *)
let test_a_question_is_answered_and_the_call_retried () =
  against
    (fun r ->
      match at [ "params"; "inputResponses" ] (body_json r) with
      | `Null ->
          answer
            (Printf.sprintf {|{"jsonrpc":"2.0","id":%s,"result":{%s}}|}
               (id_of r) asks)
      | _ ->
          answer
            (result (id_of r) {|"content":[{"type":"text","text":"deleted"}]|}))
    (fun ~client ~url ~asked ->
      let elicit ~message ~schema:_ =
        check_string "the message" "Sure?" message;
        Client.Accept (Value.Object [ ("ok", Value.Bool true) ])
      in
      let c = Client.create ~elicit client ~url in
      let (_ : Client.answer) =
        ok (Client.call_value c "delete" (Value.Object []))
      in
      match asked () with
      | [ first; retry ] ->
          check_bool "a new id" false (String.equal (id_of first) (id_of retry));
          check_string "elicitation declared" "{}"
            (Yojson.Safe.to_string
               (at
                  [
                    "params";
                    "_meta";
                    "io.modelcontextprotocol/clientCapabilities";
                    "elicitation";
                  ]
                  (body_json first)));
          check_string "the answer"
            {|{"action":"accept","content":{"ok":true}}|}
            (Yojson.Safe.to_string
               (at [ "params"; "inputResponses"; "confirm" ] (body_json retry)));
          check_string "the state echoed" {|"opaque-7"|}
            (Yojson.Safe.to_string
               (at [ "params"; "requestState" ] (body_json retry)))
      | l -> Alcotest.failf "%d requests" (List.length l))

(* mrtr §Server Requirements 7: a client that declared no elicitation has
   nothing to answer with. *)
let test_a_question_without_elicit_is_unanswered () =
  against
    (fun r ->
      answer
        (Printf.sprintf {|{"jsonrpc":"2.0","id":%s,"result":{%s}}|} (id_of r)
           asks))
    (fun ~client ~url ~asked:_ ->
      match
        Client.call_value (Client.create client ~url) "delete" (Value.Object [])
      with
      | Error (`Unanswered _) -> ()
      | Ok _ -> Alcotest.fail "answered"
      | Error e ->
          Alcotest.failf "another failure: %s" (Client.error_to_string e))

let () =
  Alcotest.run "mcp-spec"
    [
      ( "base",
        [
          Alcotest.test_case "basic §Messages: a message is one request" `Quick
            test_a_message_is_one_request;
          Alcotest.test_case "basic §_meta: the version and capabilities" `Quick
            test_a_request_carries_its_version_and_capabilities;
          Alcotest.test_case "basic §Responses: complete, naming the server"
            `Quick test_every_result_is_complete_and_names_the_server;
        ] );
      ( "transport",
        [
          Alcotest.test_case "streamable-http §Sending: a notification is 202"
            `Quick test_a_notification_is_202;
          Alcotest.test_case "streamable-http: a method not served is 404"
            `Quick test_a_method_not_served_is_404;
          Alcotest.test_case "streamable-http §Validation: headers agree" `Quick
            test_the_headers_agree_with_the_body;
          Alcotest.test_case "streamable-http §Encoding: a name in base64"
            `Quick test_a_name_in_base64_is_decoded;
          Alcotest.test_case "streamable-http §Security: another site is 403"
            `Quick test_another_sites_origin_is_refused;
          Alcotest.test_case "streamable-http §Compatibility: GET is 405" `Quick
            test_get_is_405;
        ] );
      ( "versions",
        [
          Alcotest.test_case "versioning: another version is -32022" `Quick
            test_another_version_is_unsupported;
          Alcotest.test_case "versioning: initialize names the version" `Quick
            test_initialize_names_the_supported_version;
          Alcotest.test_case "server/discover" `Quick test_discover;
        ] );
      ( "tools",
        [
          Alcotest.test_case "tools §Listing: each tool, its schemas" `Quick
            test_tools_are_listed_with_their_schemas;
          Alcotest.test_case "tools §Structured: a call's result" `Quick
            test_a_call_answers_its_structured_result;
          Alcotest.test_case "tools §Errors: a tool's failure is a result"
            `Quick test_a_tools_failure_is_a_result;
          Alcotest.test_case "tools §Errors: an unknown tool is -32602" `Quick
            test_an_unknown_tool_is_invalid_params;
          Alcotest.test_case "a tool's resource is checked at start" `Quick
            test_a_tools_resource_is_checked_at_start;
          Alcotest.test_case "routes refuses what cannot be served" `Quick
            test_routes_refuses_what_cannot_be_served;
        ] );
      ( "authorization",
        [
          Alcotest.test_case "authorization: no token is 401" `Quick
            test_a_call_without_a_token_is_401;
          Alcotest.test_case "tools §Capabilities: the list is the token's"
            `Quick test_the_list_is_the_tokens;
          Alcotest.test_case "authorization §Scope: a scope not granted is 403"
            `Quick test_a_scope_not_granted_is_403;
          Alcotest.test_case "9728 §2: the metadata names every scope" `Quick
            test_the_metadata_names_every_tools_scope;
        ] );
      ( "client",
        [
          Alcotest.test_case "scenario 5: our client calls our server" `Quick
            test_our_client_calls_our_server;
          Alcotest.test_case
            "tools §Errors: a tool's failure reaches the caller" `Quick
            test_a_tools_failure_reaches_the_caller;
          Alcotest.test_case "basic §Errors: a protocol error is a refusal"
            `Quick test_a_protocol_error_is_a_refusal;
          Alcotest.test_case "streamable-http §Metadata: every request's" `Quick
            test_every_request_carries_what_the_revision_asks;
          Alcotest.test_case "streamable-http §Encoding: a name in base64"
            `Quick test_a_name_not_plain_ascii_is_sent_in_base64;
          Alcotest.test_case "streamable-http §Sending: an event stream is read"
            `Quick test_an_answer_as_an_event_stream_is_read;
          Alcotest.test_case "tools §x-mcp-header: arguments are mirrored"
            `Quick test_annotated_arguments_are_mirrored;
          Alcotest.test_case "tools §x-mcp-header: a bad annotation is left out"
            `Quick test_a_tool_with_a_bad_annotation_is_left_out;
          Alcotest.test_case "pagination: every page is read" `Quick
            test_every_page_is_read;
          Alcotest.test_case "mrtr §Client: a question is answered, retried"
            `Quick test_a_question_is_answered_and_the_call_retried;
          Alcotest.test_case "mrtr §Server 7: no elicit, unanswered" `Quick
            test_a_question_without_elicit_is_unanswered;
        ] );
    ]
