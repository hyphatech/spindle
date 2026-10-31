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
(* Progress *)

(* A tool that reports as it goes, one report not above the last. *)
let slow =
  Mcp.tool "slow" query_json Wiretype.string
    (let+ call = Mcp.call in
     fun q ->
       Mcp.progress call ~total:3. ~message:"started" 1.;
       Mcp.progress call ~total:3. 2.;
       Mcp.progress call ~total:3. 1.5;
       Ok q.city)

let slow_app () =
  Spindle.Test.app
    ~resources:[ Spindle.Dep.resource weather temperatures ]
    (Mcp.routes ~name:"weather" ~version:"1.0.0" [ slow ])

(* An event stream's events, each ended by a blank line. *)
let blocks body =
  let ended acc = function
    | [] -> acc
    | current -> String.concat "\n" (List.rev current) :: acc
  in
  let rec go acc current = function
    | [] -> List.rev (ended acc current)
    | "" :: rest -> go (ended acc current) [] rest
    | line :: rest -> go acc (line :: current) rest
  in
  go [] [] (String.split_on_char '\n' body)

(* Each event's data, in order. *)
let events body =
  List.filter_map
    (fun block ->
      List.find_map
        (fun line ->
          if String.starts_with ~prefix:"data: " line then
            Some
              (Yojson.Safe.from_string
                 (String.sub line 6 (String.length line - 6)))
          else None)
        (String.split_on_char '\n' block))
    (blocks body)

(* progress §Progress Flow: a call that asks for progress is answered as an
   event stream, each report a notifications/progress naming its token, the
   result last. *)
let test_a_call_asking_for_progress_streams_it () =
  (* A stream runs in fibers, as a server's does. *)
  let r =
    Eio_main.run @@ fun _ ->
    Mcp.Test.call ~progress_token:"p-1" (slow_app ()) "tools/call"
      [ ("name", Value.String "slow"); ("arguments", paris) ]
  in
  check_status "200" 200 r;
  check_string "an event stream" "text/event-stream"
    (Option.value ~default:"" (Spindle.Test.header r "content-type"));
  match events r.body with
  | [ first; second; last ] ->
      check_string "a notification" {|"notifications/progress"|}
        (Yojson.Safe.to_string (at [ "method" ] first));
      check_string "its token" {|"p-1"|}
        (Yojson.Safe.to_string (at [ "params"; "progressToken" ] first));
      check_string "how far, of how much" "[1,3]"
        (Yojson.Safe.to_string
           (`List
              [
                at [ "params"; "progress" ] first;
                at [ "params"; "total" ] first;
              ]));
      check_string "its message" {|"started"|}
        (Yojson.Safe.to_string (at [ "params"; "message" ] first));
      check_string "the second" "2"
        (Yojson.Safe.to_string (at [ "params"; "progress" ] second));
      check_string "the result last" {|"Paris"|}
        (Yojson.Safe.to_string (at [ "result"; "structuredContent" ] last))
  | l -> Alcotest.failf "%d events, not 3: %s" (List.length l) r.body

(* progress §Requirements: a report not above the last is not sent. A call
   that did not ask is one JSON object, its reports dropped. *)
let test_a_call_not_asking_is_one_answer () =
  let r =
    Mcp.Test.call (slow_app ()) "tools/call"
      [ ("name", Value.String "slow"); ("arguments", paris) ]
  in
  check_string "JSON" "application/json"
    (Option.value ~default:"" (Spindle.Test.header r "content-type"));
  check_string "its result" {|"Paris"|}
    (text [ "result"; "structuredContent" ] r)

(* ------------------------------------------------------------------ *)
(* Questions *)

type confirm = { ok : bool }

let confirm_json =
  Wiretype.Object.(
    map (fun ok -> { ok })
    |> mem "ok" Wiretype.bool ~enc:(fun c -> c.ok)
    |> finish)

type reason = { why : string }

let reason_json =
  Wiretype.Object.(
    map (fun why -> { why })
    |> mem "why" Wiretype.string ~enc:(fun r -> r.why)
    |> finish)

let sure =
  Mcp.Question.form "confirm" ~message:"Delete the folder and all it holds?"
    confirm_json

let because = Mcp.Question.form "reason" ~message:"Why?" reason_json

let delete =
  Mcp.tool "delete_folder"
    ~asks:[ Mcp.Question.declare sure; Mcp.Question.declare because ]
    query_json Wiretype.string
    (let+ call = Mcp.call in
     fun q ->
       match (Mcp.answer call sure, Mcp.answer call because) with
       | Accept { ok = true }, Accept { why } ->
           Ok ("deleted " ^ q.city ^ " because " ^ why)
       | _ -> Ok "Nothing was deleted.")

let asking_app () =
  Spindle.Test.app (Mcp.routes ~name:"files" ~version:"1" [ delete ])

let forms =
  Value.Object [ ("elicitation", Value.Object [ ("form", Value.Object []) ]) ]

let delete_call ?(capabilities = forms) responses =
  Mcp.Test.call ~capabilities (asking_app ()) "tools/call"
    ([ ("name", Value.String "delete_folder"); ("arguments", paris) ]
    @
    match responses with
    | [] -> []
    | r -> [ ("inputResponses", Value.Object r) ])

let accepted content =
  Value.Object [ ("action", Value.String "accept"); ("content", content) ]

(* mrtr §Basic Workflow: a call without the answers its tool needs is
   answered input_required, every question at once, each a form. *)
let test_a_tools_questions_are_asked_at_once () =
  let r = delete_call [] in
  check_status "200" 200 r;
  check_string "input_required" {|"input_required"|}
    (text [ "result"; "resultType" ] r);
  List.iter
    (fun (key, message) ->
      let q = at [ "result"; "inputRequests"; key ] (json r) in
      check_string (key ^ ", its method") {|"elicitation/create"|}
        (Yojson.Safe.to_string (at [ "method" ] q));
      check_string (key ^ ", a form") {|"form"|}
        (Yojson.Safe.to_string (at [ "params"; "mode" ] q));
      check_string (key ^ ", its message")
        (Printf.sprintf "%S" message)
        (Yojson.Safe.to_string (at [ "params"; "message" ] q));
      check_string (key ^ ", an object") {|"object"|}
        (Yojson.Safe.to_string (at [ "params"; "requestedSchema"; "type" ] q)))
    [ ("confirm", "Delete the folder and all it holds?"); ("reason", "Why?") ];
  check_string "no state" "null" (text [ "result"; "requestState" ] r)

(* mrtr §Basic Workflow: the call made again with the answers runs the tool,
   which reads each. *)
let test_the_answers_reach_the_tool () =
  let ok = Value.Object [ ("ok", Value.Bool true) ]
  and why = Value.Object [ ("why", Value.String "tidy") ] in
  let r = delete_call [ ("confirm", accepted ok); ("reason", accepted why) ] in
  check_string "accepted" {|"deleted Paris because tidy"|}
    (text [ "result"; "structuredContent" ] r);
  let r =
    delete_call
      [
        ("confirm", Value.Object [ ("action", Value.String "decline") ]);
        ("reason", accepted why);
      ]
  in
  check_string "declined" {|"Nothing was deleted."|}
    (text [ "result"; "structuredContent" ] r)

(* mrtr §Error Handling: an answer that does not read is asked for again,
   rather than refused. *)
let test_an_unreadable_answer_is_asked_again () =
  let r =
    delete_call
      [
        ("confirm", accepted (Value.Object [ ("ok", Value.String "yes") ]));
        ("reason", accepted (Value.Object [ ("why", Value.String "tidy") ]));
      ]
  in
  check_string "input_required" {|"input_required"|}
    (text [ "result"; "resultType" ] r);
  check_bool "confirm again" true
    (match at [ "result"; "inputRequests"; "confirm" ] (json r) with
    | `Null -> false
    | _ -> true);
  check_string "reason not again" "null"
    (text [ "result"; "inputRequests"; "reason" ] r)

(* basic §_meta and mrtr §Server Requirements 7: a client that declared no
   form elicitation is never asked, and is answered -32021 naming it. *)
let test_a_client_that_answers_no_forms_is_told () =
  let r = delete_call ~capabilities:(Value.Object []) [] in
  check_error "400" ~status:400 ~code:(-32021) r;
  check_string "what it needs" "{}"
    (text [ "error"; "data"; "requiredCapabilities"; "elicitation"; "form" ] r)

(* What routes refuses of questions, each a constant written in source. *)
let test_routes_refuses_what_is_no_form () =
  let refused name asks =
    check_bool name true
      (match
         Mcp.routes ~name:"w" ~version:"1"
           [
             Mcp.tool "t" ~asks query_json Wiretype.string
               (Spindle.Dep.return (fun _ -> Ok ""));
           ]
       with
      | _ -> false
      | exception Invalid_argument _ -> true)
  in
  refused "a list for an answer"
    [
      Mcp.Question.declare
        (Mcp.Question.form "l" ~message:"?" (Wiretype.list Wiretype.string));
    ];
  refused "an object holding an object"
    [
      Mcp.Question.declare
        (Mcp.Question.form "o" ~message:"?"
           Wiretype.Object.(
             map Fun.id |> mem "inner" query_json ~enc:Fun.id |> finish));
    ];
  refused "two of one key"
    [ Mcp.Question.declare sure; Mcp.Question.declare sure ]

(* ------------------------------------------------------------------ *)
(* Resources *)

(* Journals of numbered lines, as HAF's server keeps one an intent: what a
   template reads, held by the server as a pool would be. *)
let journals : (string -> string list option) Spindle.Dep.t =
  Spindle.Dep.of_resource "journals"

let lines id =
  List.assoc_opt id [ ("0197", [ "a"; "b"; "c" ]); ("secret", [ "x" ]) ]

let machine =
  Mcp.resource "haf://machine" ~name:"machine" ~title:"This machine"
    ~doc:"Where HAF runs." ~mime:"text/plain"
    (Spindle.Dep.return (fun () -> Ok [ Mcp.Text "one machine" ]))

let logo =
  Mcp.resource "haf://logo" ~name:"logo" ~mime:"image/png"
    (Spindle.Dep.return (fun () -> Ok [ Mcp.Blob "\x89PNG" ]))

let busy =
  Mcp.resource "haf://busy" ~name:"busy"
    (Spindle.Dep.refuse (Spindle.Refusal.rate_limited ~retry_after_s:3))

let journal_variables =
  Mcp.Template.(
    let+ id = required "id" Wiretype.string
    and+ from = optional "from" (Wiretype.int_bounded ~min:1 ()) in
    (id, from))

(* Someone else's journal is refused as Access refuses it with ~deny_as, and
   a broken one as a disk that failed. *)
let journal =
  Mcp.template "haf://intents/{id}/journal{?from}" ~name:"journal"
    ~mime:"application/jsonl" ~ttl_ms:0 journal_variables
    (let+ journals = journals in
     fun (id, from) ->
       match (id, journals id) with
       | "secret", _ ->
           Error (Spindle.Refusal.make Spindle.Access.forbidden "Not yours.")
       | "broken", _ -> Error (Spindle.Refusal.internal ~detail:"the disk")
       | _, None -> Error Spindle.Refusal.not_found
       | _, Some ls ->
           let from = Option.value from ~default:1 in
           Ok
             [
               Mcp.Text
                 (String.concat "\n"
                    (List.filteri (fun i _ -> i + 1 >= from) ls));
             ])

let word =
  Mcp.template "haf://words/{word}" ~name:"word"
    Mcp.Template.(required "word" Wiretype.string)
    (Spindle.Dep.return (fun w -> Ok [ Mcp.Text w ]))

let resources = [ machine; logo; busy; journal; word ]

let resources_app () =
  Spindle.Test.app
    ~resources:[ Spindle.Dep.resource journals lines ]
    (Mcp.routes ~name:"haf" ~version:"1" ~resources [])

let read uri =
  Mcp.Test.call (resources_app ()) "resources/read"
    [ ("uri", Value.String uri) ]

(* The one content's text, as JSON. *)
let read_text uri =
  match at [ "result"; "contents" ] (json (read uri)) with
  | `List [ c ] -> Yojson.Safe.to_string (Yojson.Safe.Util.member "text" c)
  | j -> Alcotest.failf "no one content: %s" (Yojson.Safe.to_string j)

(* resources §Capabilities: a server with resources names them. *)
let test_a_server_with_resources_names_them () =
  check_string "capabilities" {|{"tools":{},"resources":{}}|}
    (text
       [ "result"; "capabilities" ]
       (Mcp.Test.call (resources_app ()) "server/discover" []))

(* resources §Listing Resources: each resource, in the order given, with what
   it says of itself; caching hints. A template is not listed here. *)
let test_resources_are_listed () =
  let r = Mcp.Test.call (resources_app ()) "resources/list" [] in
  check_string "each"
    {|[{"uri":"haf://machine","name":"machine","title":"This machine","description":"Where HAF runs.","mimeType":"text/plain"},{"uri":"haf://logo","name":"logo","mimeType":"image/png"},{"uri":"haf://busy","name":"busy"}]|}
    (text [ "result"; "resources" ] r);
  check_string "ttlMs" "300000" (text [ "result"; "ttlMs" ] r);
  check_string "cacheScope" {|"public"|} (text [ "result"; "cacheScope" ] r);
  check_error "a cursor this server never gave" ~status:200 ~code:(-32602)
    (Mcp.Test.call (resources_app ()) "resources/list"
       [ ("cursor", Value.String "next") ])

(* resources §Resource Templates: each template, its RFC 6570 text. *)
let test_templates_are_listed () =
  let r = Mcp.Test.call (resources_app ()) "resources/templates/list" [] in
  check_string "each"
    {|[{"uriTemplate":"haf://intents/{id}/journal{?from}","name":"journal","mimeType":"application/jsonl"},{"uriTemplate":"haf://words/{word}","name":"word"}]|}
    (text [ "result"; "resourceTemplates" ] r);
  check_string "ttlMs" "300000" (text [ "result"; "ttlMs" ] r)

(* resources §Reading Resources: the contents, each with the URI read and the
   resource's type, text as it is and bytes in base64; ttlMs, the resource's
   own where it has one, and cacheScope, both required. *)
let test_a_resource_is_read () =
  let r = read "haf://machine" in
  check_string "complete" {|"complete"|} (text [ "result"; "resultType" ] r);
  check_string "text"
    {|[{"uri":"haf://machine","mimeType":"text/plain","text":"one machine"}]|}
    (text [ "result"; "contents" ] r);
  check_string "ttlMs" "300000" (text [ "result"; "ttlMs" ] r);
  check_string "cacheScope" {|"public"|} (text [ "result"; "cacheScope" ] r);
  check_string "a blob"
    {|[{"uri":"haf://logo","mimeType":"image/png","blob":"iVBORw=="}]|}
    (text [ "result"; "contents" ] (read "haf://logo"));
  check_string "the resource's ttlMs" "0"
    (text [ "result"; "ttlMs" ] (read "haf://intents/0197/journal"))

(* RFC 6570 §3.2.2: a simple variable is one segment, percent-decoded, and
   never a slash. *)
let test_a_variable_is_one_segment () =
  check_string "decoded" {|"café"|} (read_text "haf://words/caf%C3%A9");
  check_error "never across a slash" ~status:200 ~code:(-32602)
    (read "haf://words/a/b");
  check_error "never empty" ~status:200 ~code:(-32602) (read "haf://words/")

(* RFC 6570 §3.2.8: a form-style query, each variable free to be absent and a
   member the template does not name ignored. *)
let test_a_query_is_read_as_a_form () =
  check_string "the whole" {|"a\nb\nc"|}
    (read_text "haf://intents/0197/journal");
  check_string "from a line" {|"b\nc"|}
    (read_text "haf://intents/0197/journal?from=2");
  check_string "a member not named" {|"c"|}
    (read_text "haf://intents/0197/journal?x=1&from=3")

(* resources §Error Handling: a URI no resource has is -32602, naming it, and
   so is one whose function finds nothing or refuses this caller its object,
   alike, so a read reveals no more than a missing one would. *)
let test_a_resource_not_found () =
  let r = read "haf://nothing" in
  check_error "none matches" ~status:200 ~code:(-32602) r;
  check_string "naming it" {|"haf://nothing"|}
    (text [ "error"; "data"; "uri" ] r);
  let message r = text [ "error"; "message" ] r in
  let none = read "haf://intents/none/journal"
  and secret = read "haf://intents/secret/journal" in
  check_error "its function found none" ~status:200 ~code:(-32602) none;
  check_error "someone else's" ~status:200 ~code:(-32602) secret;
  check_string "told alike" (message none) (message secret);
  check_string "as one none matches" (message r) (message secret)

(* resources §Error Handling: a variable that does not read is -32602,
   naming it. *)
let test_a_variable_that_does_not_read () =
  let r = read "haf://intents/0197/journal?from=twelve" in
  check_error "invalid" ~status:200 ~code:(-32602) r;
  let message = text [ "error"; "message" ] r in
  check_bool ("naming it: " ^ message) true
    (List.exists
       (fun w -> String.starts_with ~prefix:"from" w)
       (String.split_on_char ' ' message))

(* resources §Error Handling: a function's other refusal is an internal
   error; a refusal of the resource's dependency is the refusal itself. *)
let test_a_refusal_of_a_read () =
  check_error "internal" ~status:200 ~code:(-32603)
    (read "haf://intents/broken/journal");
  let r = read "haf://busy" in
  check_status "429" 429 r;
  check_string "its Retry-After" "3"
    (Option.value ~default:"" (Spindle.Test.header r "retry-after"))

let scoped_machine =
  Mcp.resource "haf://machine" ~name:"machine" ~scope:"machine:read"
    (Spindle.Dep.return (fun () -> Ok [ Mcp.Text "one machine" ]))

let scoped_journal =
  Mcp.template "haf://intents/{id}/journal" ~name:"journal"
    ~scope:"journal:read"
    Mcp.Template.(required "id" Wiretype.string)
    (Spindle.Dep.return (fun _ -> Ok [ Mcp.Text "a" ]))

let authed_resources () =
  let routes =
    Mcp.routes ~auth ~name:"haf" ~version:"1"
      ~resources:[ scoped_machine; scoped_journal; word ]
      []
  in
  Spindle.Test.app
    ~resources:
      [
        Spindle.Dep.resource (Spindle.Bearer.keys auth) (fun ~kid:_ -> [ key ]);
      ]
    (routes @ [ Spindle.Bearer.metadata auth routes ])

let authed_resource_call t meth params =
  Mcp.Test.call ~now
    ~headers:[ ("authorization", "Bearer " ^ token t) ]
    (authed_resources ()) meth params

(* resources §Capabilities, as tools': a resource whose scope the token does
   not grant is left out of both lists and its read refused 403, naming the
   scope; the metadata names every resource's scope. *)
let test_a_resources_scope () =
  let names t meth key =
    Yojson.Safe.to_string
      (`List
         (List.map
            (fun r -> at [ "name" ] r)
            (Yojson.Safe.Util.to_list
               (at [ "result"; key ] (json (authed_resource_call t meth []))))))
  in
  check_string "with the scope" {|["machine"]|}
    (names "machine:read" "resources/list" "resources");
  check_string "without it" "[]" (names "profile" "resources/list" "resources");
  check_string "templates, with it" {|["journal","word"]|}
    (names "journal:read" "resources/templates/list" "resourceTemplates");
  check_string "templates, without it" {|["word"]|}
    (names "profile" "resources/templates/list" "resourceTemplates");
  check_string "private" {|"private"|}
    (text [ "result"; "cacheScope" ]
       (authed_resource_call "profile" "resources/list" []));
  let r =
    authed_resource_call "profile" "resources/read"
      [ ("uri", Value.String "haf://intents/0197/journal") ]
  in
  check_status "403" 403 r;
  check_status "granted" 200
    (authed_resource_call "journal:read" "resources/read"
       [ ("uri", Value.String "haf://intents/0197/journal") ]);
  check_string "the metadata names both" {|["machine:read","journal:read"]|}
    (text [ "scopes_supported" ]
       (Spindle.Test.call (authed_resources ()) `GET
          "/.well-known/oauth-protected-resource/mcp"))

let test_routes_refuses_what_no_uri_reads_back () =
  let refused name ?auth resources =
    check_bool name true
      (match Mcp.routes ?auth ~name:"w" ~version:"1" ~resources [] with
      | _ -> false
      | exception Invalid_argument _ -> true)
  in
  let text = Spindle.Dep.return (fun _ -> Ok [ Mcp.Text "" ]) in
  let one t =
    Mcp.template t ~name:"t" Mcp.Template.(required "a" Wiretype.string) text
  in
  List.iter
    (fun t -> refused ("the operator of " ^ t) [ one t ])
    [
      "x://{+a}";
      "x://{#a}";
      "x://y{/a}";
      "x://y{.a}";
      "x://y{;a}";
      "x://y{&a}";
      "x://{a:3}";
      "x://{a*}";
      "x://{a,b}";
      "x://{a";
      "x://a}";
      "x://{}";
    ];
  refused "two variables side by side"
    [
      Mcp.template "x://{a}{b}" ~name:"t"
        Mcp.Template.(
          let+ a = required "a" Wiretype.string
          and+ b = required "b" Wiretype.string in
          (a, b))
        (Spindle.Dep.return (fun _ -> Ok []));
    ];
  refused "a query not last"
    [
      Mcp.template "x://y{?a}/z" ~name:"t"
        Mcp.Template.(optional "a" Wiretype.string)
        (Spindle.Dep.return (fun _ -> Ok []));
    ];
  refused "a variable named and not read" [ one "x://{a}/{b}" ];
  refused "a variable read and not named" [ one "x://y" ];
  refused "a variable read twice"
    [
      Mcp.template "x://{a}" ~name:"t"
        Mcp.Template.(
          let+ a = required "a" Wiretype.string
          and+ b = required "a" Wiretype.string in
          (a, b))
        (Spindle.Dep.return (fun _ -> Ok []));
    ];
  refused "two resources of one URI" [ machine; machine ];
  refused "two templates of one text" [ word; word ];
  refused "a scope with no auth" [ scoped_machine ]

(* ------------------------------------------------------------------ *)
(* Listening *)

let ours = "haf://intents/0197/journal"

let listening_app ?(resources = resources) changes =
  Spindle.Test.app
    ~resources:[ Spindle.Dep.resource journals lines ]
    (Mcp.routes ~name:"haf" ~version:"1" ~resources ~changes [])

let notifications uris =
  [
    ( "notifications",
      Value.Object
        [
          ( "resourceSubscriptions",
            Value.Array (List.map (fun u -> Value.String u) uris) );
        ] );
  ]

(* Every message of a listen, [on] each as it arrives; a listen is left
   once [on] answers [`Stop]. *)
let listen ?(on = fun _ -> `Continue) ?(params = []) app uris =
  let got = ref [] in
  let ended =
    Eio_main.run @@ fun _ ->
    Mcp.Test.events app "subscriptions/listen"
      (notifications uris @ params)
      (fun (e : Spindle_http.Event_stream.event) ->
        let m = Yojson.Safe.from_string e.data in
        got := m :: !got;
        on m)
  in
  (match ended with
  | Ok () -> ()
  | Error r ->
      Alcotest.failf "no stream: %d %s" (Spindle.Status.to_int r.status) r.body);
  List.rev !got

let method_of m = Yojson.Safe.to_string (at [ "method" ] m)

let is_ack m =
  String.equal (method_of m) {|"notifications/subscriptions/acknowledged"|}

let honoured m = Yojson.Safe.to_string (at [ "params"; "notifications" ] m)

(* subscriptions §Opening a Stream: the acknowledgment first, the subset
   honoured, the listen's id; then each change to a URI it watches, tagged
   with that id, and none to a URI it does not. *)
let test_a_listen_is_acknowledged_then_told () =
  let changes = Mcp.Changes.create () in
  let on m =
    if is_ack m then (
      Mcp.Changes.updated changes "haf://machine";
      Mcp.Changes.updated changes ours;
      `Continue)
    else `Stop
  in
  match listen ~on (listening_app changes) [ ours ] with
  | [ ack; updated ] ->
      check_bool "the acknowledgment first" true (is_ack ack);
      check_string "its subset"
        {|{"resourceSubscriptions":["haf://intents/0197/journal"]}|}
        (honoured ack);
      check_string "its id" "1"
        (Yojson.Safe.to_string
           (at
              [ "params"; "_meta"; "io.modelcontextprotocol/subscriptionId" ]
              ack));
      check_string "then the change" {|"notifications/resources/updated"|}
        (method_of updated);
      check_string "to the URI watched"
        ({|"|} ^ ours ^ {|"|})
        (Yojson.Safe.to_string (at [ "params"; "uri" ] updated));
      check_string "tagged" "1"
        (Yojson.Safe.to_string
           (at
              [ "params"; "_meta"; "io.modelcontextprotocol/subscriptionId" ]
              updated))
  | l -> Alcotest.failf "%d messages, not 2" (List.length l)

(* A listen is subscribed before it is acknowledged: a change made the
   instant the acknowledgment is written reaches it. *)
let test_a_change_after_the_acknowledgment_is_never_missed () =
  for _ = 1 to 100 do
    let changes = Mcp.Changes.create () in
    let on m =
      if is_ack m then (
        Mcp.Changes.updated changes ours;
        `Continue)
      else `Stop
    in
    check_int "acknowledged, then told" 2
      (List.length (listen ~on (listening_app changes) [ ours ]))
  done

(* subscriptions §Opening a Stream: the subset the server honours. A URI
   this caller may not read -- one no resource has, one whose function finds
   nothing, someone else's -- is left out alike, and no list's changes are
   honoured, since what is served is fixed. *)
let test_a_listen_honours_what_a_read_would_answer () =
  let changes = Mcp.Changes.create () in
  let first =
    listen
      ~on:(fun _ -> `Stop)
      ~params:[] (listening_app changes)
      [
        "haf://nothing";
        "haf://intents/none/journal";
        "haf://intents/secret/journal";
        ours;
        ours;
      ]
  in
  (match first with
  | [ ack ] ->
      check_string "only ours, once"
        {|{"resourceSubscriptions":["haf://intents/0197/journal"]}|}
        (honoured ack)
  | l -> Alcotest.failf "%d messages, not 1" (List.length l));
  let ack =
    Eio_main.run @@ fun _ ->
    let got = ref `Null in
    ignore
      (Mcp.Test.events (listening_app changes) "subscriptions/listen"
         [
           ( "notifications",
             Value.Object
               [
                 ("toolsListChanged", Value.Bool true);
                 ("resourcesListChanged", Value.Bool true);
                 ("promptsListChanged", Value.Bool true);
                 ("resourceSubscriptions", Value.Array [ Value.String ours ]);
               ] );
         ]
         (fun e ->
           got := Yojson.Safe.from_string e.data;
           `Stop)
        : (unit, Spindle.Test.response) result);
    !got
  in
  check_string "no list's changes"
    {|{"resourceSubscriptions":["haf://intents/0197/journal"]}|} (honoured ack)

(* A scope the token does not grant leaves the URI out, as a read would
   refuse it. *)
let test_a_listen_honours_only_what_the_token_grants () =
  let changes = Mcp.Changes.create () in
  let routes =
    Mcp.routes ~auth ~name:"haf" ~version:"1"
      ~resources:[ scoped_journal; word ] ~changes []
  in
  let app =
    Spindle.Test.app
      ~resources:
        [
          Spindle.Dep.resource (Spindle.Bearer.keys auth) (fun ~kid:_ ->
              [ key ]);
        ]
      routes
  in
  let ack t =
    Eio_main.run @@ fun _ ->
    let got = ref `Null in
    ignore
      (Mcp.Test.events ~now
         ~headers:[ ("authorization", "Bearer " ^ token t) ]
         app "subscriptions/listen"
         (notifications [ ours; "haf://words/hi" ])
         (fun e ->
           got := Yojson.Safe.from_string e.data;
           `Stop)
        : (unit, Spindle.Test.response) result);
    honoured !got
  in
  check_string "granted"
    {|{"resourceSubscriptions":["haf://intents/0197/journal","haf://words/hi"]}|}
    (ack "journal:read");
  check_string "not granted" {|{"resourceSubscriptions":["haf://words/hi"]}|}
    (ack "profile")

(* At most 64 URIs a listen, each a read as it opens and a subscription for
   as long as it lasts. *)
let test_a_listen_watches_at_most_64 () =
  let changes = Mcp.Changes.create () in
  let uris = List.init 65 (fun i -> Printf.sprintf "haf://words/w%d" i) in
  match listen ~on:(fun _ -> `Stop) (listening_app changes) uris with
  | [ ack ] ->
      check_int "64" 64
        (List.length
           (Yojson.Safe.Util.to_list
              (at [ "params"; "notifications"; "resourceSubscriptions" ] ack)))
  | l -> Alcotest.failf "%d messages, not 1" (List.length l)

let graceful = function
  | `Assoc members -> (
      match List.assoc_opt "result" members with
      | Some result ->
          String.equal
            (Yojson.Safe.to_string (at [ "resultType" ] result))
            {|"complete"|}
      | None -> false)
  | _ -> false

(* subscriptions §Cancellation: a server that ends a listen sends the
   graceful result, carrying the listen's id, and never
   notifications/cancelled, which HTTP has no use for (#3348, read as the
   Subscriptions page has it). *)
let test_a_server_ends_a_listen_gracefully () =
  let changes = Mcp.Changes.create () in
  let on m =
    if is_ack m then Mcp.Changes.close changes;
    `Continue
  in
  match listen ~on (listening_app changes) [ ours ] with
  | [ _; result ] ->
      check_bool "the graceful result" true (graceful result);
      check_string "the listen's id" "1"
        (Yojson.Safe.to_string
           (at
              [ "result"; "_meta"; "io.modelcontextprotocol/subscriptionId" ]
              result));
      check_string "the response to the listen" "1"
        (Yojson.Safe.to_string (at [ "id" ] result))
  | l -> Alcotest.failf "%d messages, not 2" (List.length l)

(* A listen ends gracefully only when the server ended it: one dropped as
   slow ends with no result, so its client listens again. *)
let test_a_listen_dropped_as_slow_ends_without_a_result () =
  let changes = Mcp.Changes.create ~depth:1 () in
  let on m =
    if is_ack m then
      for _ = 1 to 3 do
        Mcp.Changes.updated changes ours
      done;
    `Continue
  in
  match listen ~on (listening_app changes) [ ours ] with
  | ack :: rest ->
      check_bool "acknowledged" true (is_ack ack);
      check_bool "no result" false (List.exists graceful rest)
  | [] -> Alcotest.fail "nothing at all"

(* streamable-http §Cancellation: a client closing the stream ends the
   listen, and nothing of it is kept. *)
let test_a_client_that_leaves_leaves_nothing () =
  let changes = Mcp.Changes.create () in
  ignore
    (listen ~on:(fun _ -> `Stop) (listening_app changes) [ ours ]
      : Yojson.Safe.t list);
  check_int "nothing watched" 0
    (Eio_main.run @@ fun _ -> List.length (Mcp.Changes.watched changes))

(* A listen that watches nothing is acknowledged with nothing and ends at
   once, gracefully: as an event stream nothing between may hold. *)
let test_a_listen_of_nothing_ends_at_once () =
  let changes = Mcp.Changes.create () in
  let r =
    Mcp.Test.call (listening_app changes) "subscriptions/listen"
      (notifications [ "haf://nothing" ])
  in
  check_string "an event stream" "text/event-stream"
    (Option.value ~default:"" (Spindle.Test.header r "content-type"));
  check_string "nothing holds it" "no"
    (Option.value ~default:"" (Spindle.Test.header r "x-accel-buffering"));
  match events r.body with
  | [ ack; result ] ->
      check_string "acknowledged with nothing" "{}" (honoured ack);
      check_bool "then the result" true (graceful result)
  | l -> Alcotest.failf "%d messages, not 2: %s" (List.length l) r.body

(* subscriptions §Opening a Stream: notifications is required. *)
let test_a_listen_names_what_it_wants () =
  check_error "-32602" ~status:200 ~code:(-32602)
    (Mcp.Test.call
       (listening_app (Mcp.Changes.create ()))
       "subscriptions/listen" [])

(* resources §Capabilities: subscribe is named where the server listens,
   and a server that does not answers listen as a method not served. *)
let test_subscribe_is_named_where_served () =
  check_string "subscribe" {|{"tools":{},"resources":{"subscribe":true}}|}
    (text
       [ "result"; "capabilities" ]
       (Mcp.Test.call
          (listening_app (Mcp.Changes.create ()))
          "server/discover" []));
  check_error "not served" ~status:404 ~code:(-32601)
    (Mcp.Test.call (resources_app ()) "subscriptions/listen"
       (notifications [ ours ]))

(* ------------------------------------------------------------------ *)
(* The client *)

module Client = Spindle_mcp_client

(* A Spindle server on a socket of its own, and a client to call it. *)
let over_a_socket ?elicit
    ?(routes = Mcp.routes ~name:"weather" ~version:"1.0.0" tools) ?(given = [])
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
           ~resources:(Spindle.Dep.resource weather temperatures :: given)
           routes);
      `Stop_daemon);
  Spindle_client.run env @@ fun client ->
  f
    (Client.create ?elicit client
       ~url:(Printf.sprintf "http://127.0.0.1:%d/mcp" port))

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

let over_resources f =
  over_a_socket
    ~routes:(Mcp.routes ~name:"haf" ~version:"1" ~resources [])
    ~given:[ Spindle.Dep.resource journals lines ]
    f

(* resources §Listing Resources, §Resource Templates: our client lists our
   server's resources and templates, each with what it says of itself. *)
let test_our_client_lists_our_resources () =
  over_resources @@ fun c ->
  let resources = ok (Client.resources c) in
  check_string "each resource" "haf://machine,haf://logo,haf://busy"
    (String.concat ","
       (List.map (fun (r : Client.resource) -> r.uri) resources));
  (match resources with
  | m :: _ ->
      check_string "its name" "machine" m.name;
      check_string "its title" "This machine" (Option.value ~default:"" m.title);
      check_string "its description" "Where HAF runs."
        (Option.value ~default:"" m.description);
      check_string "its type" "text/plain" (Option.value ~default:"" m.mime)
  | [] -> Alcotest.fail "no resources");
  check_string "each template"
    "haf://intents/{id}/journal{?from},haf://words/{word}"
    (String.concat ","
       (List.map
          (fun (t : Client.template) -> t.uri_template)
          (ok (Client.templates c))))

(* resources §Reading Resources: our client reads text as it is and a blob
   decoded, each with its URI and type, the URI mirrored in Mcp-Name. *)
let test_our_client_reads_our_resources () =
  over_resources @@ fun c ->
  (match ok (Client.read c "haf://intents/0197/journal?from=2") with
  | [ { uri; mime; data = Text t } ] ->
      check_string "the URI read" "haf://intents/0197/journal?from=2" uri;
      check_string "its type" "application/jsonl"
        (Option.value ~default:"" mime);
      check_string "its text" "b\nc" t
  | _ -> Alcotest.fail "not one text");
  (match ok (Client.read c "haf://logo") with
  | [ { data = Blob b; _ } ] -> check_string "the bytes" "\x89PNG" b
  | _ -> Alcotest.fail "not one blob");
  match Client.read c "haf://nothing" with
  | Error (`Refused { code = Some -32602; _ }) -> ()
  | Ok _ -> Alcotest.fail "a resource none has was read"
  | Error e -> Alcotest.failf "not -32602: %s" (Client.error_to_string e)

(* pagination: every page of resources and of templates is read. *)
let test_every_page_of_resources_is_read () =
  against
    (fun r ->
      let key =
        match at [ "method" ] (body_json r) with
        | `String "resources/list" -> "resources"
        | _ -> "resourceTemplates"
      and field =
        match at [ "method" ] (body_json r) with
        | `String "resources/list" -> "uri"
        | _ -> "uriTemplate"
      in
      match at [ "params"; "cursor" ] (body_json r) with
      | `Null ->
          answer
            (result (id_of r)
               (Printf.sprintf
                  {|%S:[{%S:"x://a","name":"a"}],"nextCursor":"2","ttlMs":0,"cacheScope":"public"|}
                  key field))
      | _ ->
          answer
            (result (id_of r)
               (Printf.sprintf
                  {|%S:[{%S:"x://b","name":"b"}],"ttlMs":0,"cacheScope":"public"|}
                  key field)))
    (fun ~client ~url ~asked:_ ->
      let c = Client.create client ~url in
      check_string "both pages of resources" "x://a,x://b"
        (String.concat ","
           (List.map
              (fun (r : Client.resource) -> r.uri)
              (ok (Client.resources c))));
      check_string "both pages of templates" "x://a,x://b"
        (String.concat ","
           (List.map
              (fun (t : Client.template) -> t.uri_template)
              (ok (Client.templates c)))))

let over_listening ?(changes = Mcp.Changes.create ()) f =
  over_a_socket
    ~routes:(Mcp.routes ~name:"haf" ~version:"1" ~resources ~changes [])
    ~given:[ Spindle.Dep.resource journals lines ]
    (f changes)

(* subscriptions §Opening a Stream, as a client: the acknowledgment first,
   then each change, until the caller stops. *)
let test_our_client_listens_to_our_server () =
  over_listening @@ fun changes c ->
  let told = ref [] in
  let ended =
    Client.listen c [ ours; "haf://nothing" ] (fun n ->
        told := n :: !told;
        match n with
        | Acknowledged _ ->
            Mcp.Changes.updated changes ours;
            `Continue
        | Updated _ -> `Stop)
  in
  (match ok ended with
  | Stopped -> ()
  | Completed | Dropped _ -> Alcotest.fail "not stopped by the caller");
  match List.rev !told with
  | [ Acknowledged honoured; Updated uri ] ->
      check_string "the acknowledgment names what is watched" ours
        (String.concat "," honoured);
      check_string "then the change" ours uri
  | l -> Alcotest.failf "%d notifications, not 2" (List.length l)

(* subscriptions §Cancellation, as a client: the server's graceful result is
   Completed, which the caller does not listen again after. *)
let test_a_listen_the_server_ends_is_completed () =
  over_listening @@ fun changes c ->
  match
    Client.listen c [ ours ] (function
      | Acknowledged _ ->
          Mcp.Changes.close changes;
          `Continue
      | Updated _ -> `Continue)
  with
  | Ok Completed -> ()
  | Ok (Stopped | Dropped _) -> Alcotest.fail "not completed"
  | Error e -> Alcotest.fail (Client.error_to_string e)

let acknowledged id =
  Printf.sprintf
    {|event: message
data: {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":%s},"notifications":{"resourceSubscriptions":["x://a"]}}}

|}
    id

let updated ~id uri =
  Printf.sprintf
    {|event: message
data: {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":%S,"_meta":{"io.modelcontextprotocol/subscriptionId":%s}}}

|}
    uri id

(* A stream that ends without the result is Dropped, which the caller
   listens again after; a notification of another listen is not told. The
   request asks for the URIs, in the headers and the body 2026-07-28 asks. *)
let test_a_listen_cut_off_is_dropped () =
  against
    (fun r ->
      let id = id_of r in
      answer ~content_type:"text/event-stream"
        (acknowledged id ^ updated ~id:"999" "x://other" ^ updated ~id "x://a"))
    (fun ~client ~url ~asked ->
      let told = ref [] in
      let ended =
        Client.listen (Client.create client ~url) [ "x://a" ] (fun n ->
            told := n :: !told;
            `Continue)
      in
      (match ok ended with
      | Dropped _ -> ()
      | Stopped | Completed -> Alcotest.fail "not dropped");
      check_int "the acknowledgment and our change" 2 (List.length !told);
      match asked () with
      | [ r ] ->
          check_string "the method" {|"subscriptions/listen"|}
            (Yojson.Safe.to_string (at [ "method" ] (body_json r)));
          check_string "the URIs" {|["x://a"]|}
            (Yojson.Safe.to_string
               (at
                  [ "params"; "notifications"; "resourceSubscriptions" ]
                  (body_json r)));
          check_string "Mcp-Method" "subscriptions/listen"
            (Option.value ~default:"" (List.assoc_opt "mcp-method" r.headers))
      | l -> Alcotest.failf "%d requests, not 1" (List.length l))

(* basic §Errors, as a listen: a refusal before the acknowledgment is an
   error, never an end. *)
let test_a_listen_refused_is_an_error () =
  against
    (fun r ->
      Stub_server.reply
        ~headers:[ ("content-type", "application/json") ]
        `Not_found
        (Printf.sprintf
           {|{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}|}
           (id_of r)))
    (fun ~client ~url ~asked:_ ->
      match
        Client.listen (Client.create client ~url) [ "x://a" ] (fun _ ->
            `Continue)
      with
      | Error (`Refused { code = Some -32601; _ }) -> ()
      | Ok _ -> Alcotest.fail "an end"
      | Error e -> Alcotest.failf "not -32601: %s" (Client.error_to_string e))

(* A journal that grows as it is watched, numbered lines from 1. *)
type book = { lock : Eio.Mutex.t; mutable written : string list }

let book : book Spindle.Dep.t = Spindle.Dep.of_resource "book"

let growing =
  Mcp.template "haf://intents/{id}/journal{?from}" ~name:"journal" ~ttl_ms:0
    journal_variables
    (let+ book = book in
     fun (_, from) ->
       match from with
       | None -> Ok []
       | Some from ->
           Eio.Mutex.use_ro book.lock (fun () ->
               Ok
                 (List.filteri
                    (fun i _ -> i + 1 >= from)
                    (List.rev_map (fun l -> Mcp.Text l) book.written))))

(* Verification: a client watching a journal as 200 lines are written --
   listens dropped as slow, a hub one change deep, and listens the client
   leaves at points a seeded generator chooses -- ends holding every line,
   once, in order. *)
let test_a_watch_misses_no_line () =
  let lines = 200 in
  let changes = Mcp.Changes.create ~depth:1 () in
  let written = { lock = Eio.Mutex.create (); written = [] } in
  over_a_socket
    ~routes:
      (Mcp.routes ~name:"haf" ~version:"1" ~resources:[ growing ] ~changes [])
    ~given:[ Spindle.Dep.resource book written ]
  @@ fun c ->
  let rng = Random.State.make [| 7 |] in
  let got = ref [] in
  let have () = List.length !got in
  let catch_up () =
    match Client.read c (Printf.sprintf "%s?from=%d" ours (have () + 1)) with
    | Ok contents ->
        List.iter
          (fun (content : Client.content) ->
            match content.data with
            | Text l -> got := l :: !got
            | Blob _ -> Alcotest.fail "a blob")
          contents
    | Error e -> Alcotest.fail (Client.error_to_string e)
  in
  let rec watch () =
    if have () < lines then
      match
        Client.listen c [ ours ] (fun _ ->
            catch_up ();
            if have () >= lines || Random.State.int rng 8 = 0 then `Stop
            else `Continue)
      with
      | Ok (Stopped | Dropped _) -> watch ()
      | Ok Completed -> Alcotest.fail "the server ended it"
      | Error e -> Alcotest.fail (Client.error_to_string e)
  in
  Eio.Fiber.both
    (fun () ->
      for n = 1 to lines do
        Eio.Mutex.use_rw ~protect:true written.lock (fun () ->
            written.written <- string_of_int n :: written.written);
        Mcp.Changes.updated changes ours;
        Eio.Fiber.yield ()
      done)
    watch;
  check_string "every line, once, in order"
    (String.concat "," (List.init lines (fun i -> string_of_int (i + 1))))
    (String.concat "," (List.rev !got))

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

(* progress: the client hands each report to its caller, as it arrives, and
   asks for them only when it has somewhere to send them. *)
let test_the_client_reports_progress () =
  over_a_socket ~routes:(Mcp.routes ~name:"weather" ~version:"1.0.0" [ slow ])
  @@ fun c ->
  let seen = ref [] in
  let a =
    ok
      (Client.call_value c "slow"
         ~progress:(fun (p : Client.progress) -> seen := p.progress :: !seen)
         paris)
  in
  check_bool "its result" true (Option.is_some a.structured);
  Alcotest.(check (list (float 0.))) "each report" [ 1.; 2. ] (List.rev !seen)

(* Scenario 3: our client answers our server's questions through the
   function it was given, and the tool runs on the answers. *)
let test_our_client_answers_our_servers_questions () =
  let asked = ref [] in
  let elicit ~message ~schema:_ =
    asked := message :: !asked;
    match message with
    | "Why?" -> Client.Accept (Value.Object [ ("why", Value.String "tidy") ])
    | _ -> Client.Accept (Value.Object [ ("ok", Value.Bool true) ])
  in
  over_a_socket ~elicit
    ~routes:(Mcp.routes ~name:"files" ~version:"1" [ delete ])
  @@ fun c ->
  let r =
    ok
      (Client.call c "delete_folder" query_json { city = "Paris" }
         Wiretype.string)
  in
  check_string "the tool ran on them" "deleted Paris because tidy" r;
  check_int "both asked" 2 (List.length !asked)

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
      ( "resources",
        [
          Alcotest.test_case "resources §Capabilities: discovery names them"
            `Quick test_a_server_with_resources_names_them;
          Alcotest.test_case "resources §Listing: each resource" `Quick
            test_resources_are_listed;
          Alcotest.test_case "resources §Templates: each template" `Quick
            test_templates_are_listed;
          Alcotest.test_case "resources §Reading: the contents" `Quick
            test_a_resource_is_read;
          Alcotest.test_case "6570 §3.2.2: a variable is one segment" `Quick
            test_a_variable_is_one_segment;
          Alcotest.test_case "6570 §3.2.8: a query is read as a form" `Quick
            test_a_query_is_read_as_a_form;
          Alcotest.test_case "resources §Errors: not found, alike" `Quick
            test_a_resource_not_found;
          Alcotest.test_case "resources §Errors: a variable that does not read"
            `Quick test_a_variable_that_does_not_read;
          Alcotest.test_case "resources §Errors: a read's refusal" `Quick
            test_a_refusal_of_a_read;
          Alcotest.test_case "resources §Capabilities: a resource's scope"
            `Quick test_a_resources_scope;
          Alcotest.test_case "routes refuses what no URI reads back" `Quick
            test_routes_refuses_what_no_uri_reads_back;
        ] );
      ( "listening",
        [
          Alcotest.test_case "subscriptions §Opening: acknowledged, then told"
            `Quick test_a_listen_is_acknowledged_then_told;
          Alcotest.test_case "a change after the acknowledgment is never missed"
            `Quick test_a_change_after_the_acknowledgment_is_never_missed;
          Alcotest.test_case "subscriptions §Opening: what a read would answer"
            `Quick test_a_listen_honours_what_a_read_would_answer;
          Alcotest.test_case "subscriptions §Opening: what the token grants"
            `Quick test_a_listen_honours_only_what_the_token_grants;
          Alcotest.test_case "a listen watches at most 64" `Quick
            test_a_listen_watches_at_most_64;
          Alcotest.test_case "subscriptions §Cancellation: the server's result"
            `Quick test_a_server_ends_a_listen_gracefully;
          Alcotest.test_case "a listen dropped as slow ends without a result"
            `Quick test_a_listen_dropped_as_slow_ends_without_a_result;
          Alcotest.test_case "streamable-http §Cancellation: nothing is kept"
            `Quick test_a_client_that_leaves_leaves_nothing;
          Alcotest.test_case "a listen of nothing ends at once" `Quick
            test_a_listen_of_nothing_ends_at_once;
          Alcotest.test_case "subscriptions §Opening: notifications required"
            `Quick test_a_listen_names_what_it_wants;
          Alcotest.test_case "resources §Capabilities: subscribe" `Quick
            test_subscribe_is_named_where_served;
        ] );
      ( "questions",
        [
          Alcotest.test_case "mrtr §Basic: a tool's questions, at once" `Quick
            test_a_tools_questions_are_asked_at_once;
          Alcotest.test_case "mrtr §Basic: the answers reach the tool" `Quick
            test_the_answers_reach_the_tool;
          Alcotest.test_case "mrtr §Errors: an unreadable answer, again" `Quick
            test_an_unreadable_answer_is_asked_again;
          Alcotest.test_case "mrtr §Server 7: no form elicitation is -32021"
            `Quick test_a_client_that_answers_no_forms_is_told;
          Alcotest.test_case "routes refuses a question that is no form" `Quick
            test_routes_refuses_what_is_no_form;
          Alcotest.test_case "scenario 3: our client answers our server" `Quick
            test_our_client_answers_our_servers_questions;
        ] );
      ( "progress",
        [
          Alcotest.test_case "progress §Flow: a call asking streams it" `Quick
            test_a_call_asking_for_progress_streams_it;
          Alcotest.test_case "progress: a call not asking is one answer" `Quick
            test_a_call_not_asking_is_one_answer;
          Alcotest.test_case "progress: the client reports it" `Quick
            test_the_client_reports_progress;
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
          Alcotest.test_case "resources §Listing: our client lists ours" `Quick
            test_our_client_lists_our_resources;
          Alcotest.test_case "resources §Reading: our client reads ours" `Quick
            test_our_client_reads_our_resources;
          Alcotest.test_case "pagination: every page of resources" `Quick
            test_every_page_of_resources_is_read;
          Alcotest.test_case "subscriptions §Opening: our client listens" `Quick
            test_our_client_listens_to_our_server;
          Alcotest.test_case "subscriptions §Cancellation: completed" `Quick
            test_a_listen_the_server_ends_is_completed;
          Alcotest.test_case "subscriptions §Cancellation: cut off, dropped"
            `Quick test_a_listen_cut_off_is_dropped;
          Alcotest.test_case "basic §Errors: a listen refused is an error"
            `Quick test_a_listen_refused_is_an_error;
          Alcotest.test_case "verification: a watch misses no line" `Quick
            test_a_watch_misses_no_line;
          Alcotest.test_case "mrtr §Client: a question is answered, retried"
            `Quick test_a_question_is_answered_and_the_call_retried;
          Alcotest.test_case "mrtr §Server 7: no elicit, unanswered" `Quick
            test_a_question_without_elicit_is_unanswered;
        ] );
    ]
