module P = Spindle_mcp_protocol
module Dep = Spindle.Dep
module Bearer = Spindle.Bearer
module Value = Wiretype.Value
module Schema = Wiretype.Schema
open Spindle.Syntax

(* What a call of a tool came to. *)
type outcome =
  | Answered of { structured : Value.t; text : string }
  | Failed of string  (** for the model: the problems, or the sentence *)
  | Broken of string  (** a result its own description cannot write: ours *)

type tool = {
  name : string;
  title : string option;
  doc : string option;
  scope : string option;
  input : (Value.t, string) result;  (** [Error] where it is no object *)
  output : Value.t;
  may_refuse : bool;
  run : (Value.t -> outcome) Dep.t;
}

(* A description's JSON Schema 2020-12, its kinds under [$defs]; a root that
   is a kind is written as that kind itself, since MCP reads an input's root
   for its type. *)
let schema dir ~at description =
  let ctx = Schema.create () in
  let root = Schema.walk ctx dir ~at description in
  let components = Schema.components ctx in
  let root =
    match root with
    | Schema.Ref name -> (
        match List.assoc_opt (Schema.name_of_kind name) components with
        | Some (Schema.Object _ as o) -> o
        | Some _ | None -> root)
    | _ -> root
  in
  (root, Schema.Json_schema.document components root)

let tool ?title ?doc ?scope name arguments result f =
  let input =
    match schema Schema.Decode ~at:name arguments with
    | Schema.Object _, document -> Ok document
    | _ -> Error "arguments whose description is no object"
  in
  let _, output = schema Schema.Encode ~at:name result in
  let call f args =
    match Wiretype.of_value arguments args with
    | Error problems ->
        Failed
          (String.concat "; " (List.map Wiretype.Problem.to_string problems))
    | Ok a -> (
        match f a with
        | Error (refusal : Spindle.Refusal.t) -> Failed refusal.message
        | Ok r -> (
            match (Wiretype.to_value result r, Wiretype.encode result r) with
            | Ok structured, Ok text -> Answered { structured; text }
            | Error e, _ | _, Error e ->
                Broken (Wiretype.Unwritable.to_string e)))
  in
  {
    name;
    title;
    doc;
    scope;
    input;
    output;
    may_refuse = (match Dep.codes f with [] -> false | _ :: _ -> true);
    run = Dep.map call f;
  }

(* tools §Tool Names: what a name SHOULD be, held as a MUST, since a name is
   written in source. *)
let max_name = 128

let is_name s =
  let n = String.length s in
  n > 0 && n <= max_name
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '.' -> true
         | _ -> false)
       s

let refuse why = invalid_arg ("Spindle_mcp.routes: " ^ why)

let check ~auth tools =
  List.iteri
    (fun i (t : tool) ->
      if not (is_name t.name) then
        refuse (Printf.sprintf "%S is no tool name MCP reads" t.name);
      if
        List.exists
          (fun (u : tool) -> String.equal u.name t.name)
          (List.filteri (fun j _ -> j < i) tools)
      then refuse (Printf.sprintf "two tools are named %S" t.name);
      (match t.input with
      | Error why -> refuse (Printf.sprintf "%S takes %s" t.name why)
      | Ok _ -> ());
      (match (t.scope, auth) with
      | Some _, None ->
          refuse
            (Printf.sprintf "%S needs a scope, and no auth is given" t.name)
      | _ -> ());
      if t.may_refuse then
        refuse
          (Printf.sprintf
             "%S's dependency may refuse, which would refuse every call" t.name))
    tools

let opt name = function Some v -> [ (name, Value.String v) ] | None -> []

let json ?(status = `OK) text =
  Ok (Spindle.Response.make ~status ~content_type:"application/json" text)

(* streamable-http §Value Encoding: a value that is no plain ASCII is sent
   as [=?base64?...?=]. *)
let decoded_name value =
  let prefix = "=?base64?" and suffix = "?=" in
  let n = String.length value in
  if
    String.starts_with ~prefix value
    && String.ends_with ~suffix value
    && n >= String.length prefix + String.length suffix
  then
    Result.to_option
      (Base64.decode
         (String.sub value (String.length prefix)
            (n - String.length prefix - String.length suffix)))
  else Some value

(* The methods whose name or URI is mirrored in [Mcp-Name]. *)
let named_by meth params =
  match meth with
  | "tools/call" | "prompts/get" -> (
      match P.member "name" params with
      | Some (Value.String n) -> Some (Some n)
      | _ -> Some None)
  | "resources/read" -> (
      match P.member "uri" params with
      | Some (Value.String u) -> Some (Some u)
      | _ -> Some None)
  | _ -> None

let routes ?(path = Spindle.Path.(s "mcp")) ?guard ?auth ?instructions
    ?(ttl_ms = 300_000) ~name ~version tools =
  check ~auth tools;
  let served =
    Value.Object
      [ ("name", Value.String name); ("version", Value.String version) ]
  in
  let result_meta =
    ("_meta", Value.Object [ ("io.modelcontextprotocol/serverInfo", served) ])
  in
  (* caching §Cache Scope: a list filtered by the token is the token's. *)
  let cacheable =
    [
      ("ttlMs", Value.Number (float_of_int ttl_ms));
      ( "cacheScope",
        Value.String (match auth with Some _ -> "private" | None -> "public") );
    ]
  in
  let scopes =
    List.fold_left
      (fun acc (t : tool) ->
        match t.scope with
        | Some s when not (List.exists (String.equal s) acc) -> acc @ [ s ]
        | Some _ | None -> acc)
      [] tools
  in
  let claims =
    match auth with
    | None -> Dep.return None
    | Some a ->
        Dep.map Option.some
          (Dep.credential ~scheme:"bearer" ~scopes (Bearer.claims a))
  in
  let runs =
    List.fold_right
      (fun (t : tool) acc ->
        Dep.map (fun (f, rest) -> (t, f) :: rest) (Dep.both t.run acc))
      tools (Dep.return [])
  in
  let header h = Spindle.Header.optional h Spindle.Codec.string in
  let grants (t : tool) (claims : Bearer.claims option) =
    match (t.scope, claims) with
    | Some s, Some c -> List.exists (String.equal s) c.scopes
    | Some _, None | None, _ -> true
  in
  let answer ~id ~meth ~params ~claims ~runs =
    let ok members = json (P.result id (members @ [ result_meta ])) in
    let fail ?(status = `OK) ?data code message =
      json ~status (P.error ~id ?data code message)
    in
    let complete = ("resultType", Value.String "complete") in
    match meth with
    | "server/discover" ->
        ok
          ([
             complete;
             ("supportedVersions", Value.Array [ Value.String P.version ]);
             ("capabilities", Value.Object [ ("tools", Value.Object []) ]);
           ]
          @ opt "instructions" instructions
          @ cacheable)
    | "tools/list" -> (
        match P.member "cursor" params with
        (* pagination: this server gives no cursor, so any is unknown. *)
        | Some _ -> fail P.Code.invalid_params "Invalid params: no such cursor"
        | None ->
            let listed (t : tool) =
              Value.Object
                ([ ("name", Value.String t.name) ]
                @ opt "title" t.title @ opt "description" t.doc
                @ [
                    ( "inputSchema",
                      match t.input with Ok s -> s | Error _ -> Value.Null );
                    ("outputSchema", t.output);
                  ])
            in
            ok
              ([
                 complete;
                 ( "tools",
                   Value.Array
                     (List.filter_map
                        (fun ((t : tool), _) ->
                          if grants t claims then Some (listed t) else None)
                        runs) );
               ]
              @ cacheable))
    | "tools/call" -> (
        let called =
          match P.member "name" params with
          | Some (Value.String n) ->
              List.find_opt (fun ((t : tool), _) -> String.equal t.name n) runs
          | _ -> None
        in
        match called with
        | None -> fail P.Code.invalid_params "Invalid params: no such tool"
        | Some (t, _) when not (grants t claims) -> (
            match (auth, t.scope) with
            | Some a, Some s -> Error (Bearer.lacking a s)
            | _ -> fail P.Code.invalid_params "Invalid params: no such tool")
        | Some (_, run) -> (
            let arguments =
              Option.value
                (P.member "arguments" params)
                ~default:(Value.Object [])
            in
            let content text =
              ( "content",
                Value.Array
                  [
                    Value.Object
                      [
                        ("type", Value.String "text");
                        ("text", Value.String text);
                      ];
                  ] )
            in
            match run arguments with
            | Answered { structured; text } ->
                ok
                  [
                    complete;
                    content text;
                    ("structuredContent", structured);
                    ("isError", Value.Bool false);
                  ]
            | Failed why ->
                ok [ complete; content why; ("isError", Value.Bool true) ]
            | Broken why -> Error (Spindle.Refusal.internal ~detail:why)))
    | _ -> fail ~status:`Not_found P.Code.method_not_found "Method not found"
  in
  (* streamable-http §Server Validation, then basic §_meta, then versioning:
     each a 400 with its code, before the method is served. *)
  let checked ~id ~meth ~params ~version_header ~method_header ~name_header k =
    let fail ?data code message =
      json ~status:`Bad_request (P.error ~id ?data code message)
    in
    let mismatch what =
      fail P.Code.header_mismatch ("Header mismatch: " ^ what)
    in
    let meta = P.member "_meta" params in
    let unsupported requested =
      fail
        ~data:
          (Value.Object
             [
               ("supported", Value.Array [ Value.String P.version ]);
               ("requested", Value.String requested);
             ])
        P.Code.unsupported_version "Unsupported protocol version"
    in
    match (meth, version_header, method_header) with
    (* versioning §Backward Compatibility: a legacy client opens with
       initialize, its version in its params and in no header; the version
       spoken here is the one thing it can show its user. *)
    | "initialize", _, _ -> (
        match P.member "protocolVersion" params with
        | Some (Value.String v) -> unsupported v
        | _ -> unsupported "")
    | _, None, _ -> mismatch "no MCP-Protocol-Version"
    | _, _, None -> mismatch "no Mcp-Method"
    | _, Some _, Some m when not (String.equal m meth) ->
        mismatch "Mcp-Method is not the body's method"
    | _, Some v, Some _ -> (
        let name_ok =
          match named_by meth params with
          | None -> true
          | Some body_name -> (
              match (Option.bind name_header decoded_name, body_name) with
              | Some h, Some b -> String.equal h b
              | _ -> false)
        in
        if not name_ok then mismatch "Mcp-Name is not the body's"
        else
          match
            ( P.member "io.modelcontextprotocol/protocolVersion" meta,
              P.member "io.modelcontextprotocol/clientCapabilities" meta )
          with
          | Some (Value.String requested), Some (Value.Object _) ->
              if not (String.equal requested v) then
                mismatch "MCP-Protocol-Version is not _meta's"
              else if not (String.equal requested P.version) then
                unsupported requested
              else k ()
          | _ ->
              fail P.Code.invalid_params
                "Invalid params: _meta names no protocol version or client \
                 capabilities")
  in
  let guard = Option.value guard ~default:(Dep.return ()) in
  [
    Spindle.post
      ~refuses:
        (match auth with Some _ -> [ Bearer.insufficient_scope ] | None -> [])
      path Spindle.Returns.response
      (let+ () = guard
       and+ claims = claims
       and+ version_header = header "mcp-protocol-version"
       and+ method_header = header "mcp-method"
       and+ name_header = header "mcp-name"
       and+ runs = runs
       and+ body = Spindle.body in
       match P.read body with
       | Error Parse_error ->
           json ~status:`Bad_request (P.error P.Code.parse_error "Parse error")
       | Error (Invalid_request why) ->
           json ~status:`Bad_request
             (P.error P.Code.invalid_request ("Invalid request: " ^ why))
       (* streamable-http §Sending Messages: a notification accepted is 202,
          with no body. *)
       | Ok (Notification _) -> Ok (Spindle.Response.make ~status:`Accepted "")
       | Ok (Request { id; meth; params }) ->
           checked ~id ~meth ~params ~version_header ~method_header ~name_header
             (fun () -> answer ~id ~meth ~params ~claims ~runs));
  ]

module Test = struct
  let call ?now ?(path = "/mcp") ?(headers = [])
      ?(capabilities = Value.Object []) app meth params =
    let meta =
      Value.Object
        [
          ("io.modelcontextprotocol/protocolVersion", Value.String P.version);
          ("io.modelcontextprotocol/clientCapabilities", capabilities);
        ]
    in
    let body =
      Value.Object
        [
          ("jsonrpc", Value.String "2.0");
          ("id", Value.Number 1.);
          ("method", Value.String meth);
          ("params", Value.Object (params @ [ ("_meta", meta) ]));
        ]
    in
    let named =
      match List.assoc_opt "name" params with
      | Some (Value.String n) -> [ ("mcp-name", n) ]
      | _ -> (
          match List.assoc_opt "uri" params with
          | Some (Value.String u) -> [ ("mcp-name", u) ]
          | _ -> [])
    in
    let text =
      match Wiretype.encode Value.json body with
      | Ok s -> s
      | Error e -> invalid_arg (Wiretype.Unwritable.to_string e)
    in
    Spindle.Test.call ?now
      ~headers:
        ([
           ("content-type", "application/json");
           ("accept", "application/json, text/event-stream");
           ("mcp-protocol-version", P.version);
           ("mcp-method", meth);
         ]
        @ named @ headers)
      ~body:text app `POST path
end
