module P = Spindle_mcp_protocol
module Value = Wiretype.Value
module Media_type = Spindle_http.Media_type
module Event_stream = Spindle_http.Event_stream
module Oauth = Spindle_client.Oauth

let src =
  Logs.Src.create "spindle-mcp-client" ~doc:"Calls of other servers' tools"

module L = (val Logs.src_log src : Logs.LOG)

type reply = Accept of Value.t | Decline | Cancel
type elicit = message:string -> schema:Value.t -> reply

type tool = {
  name : string;
  title : string option;
  description : string option;
  input_schema : Value.t;
  output_schema : Value.t option;
}

(* What a listed tool says to mirror: an argument's path, by [properties]
   alone, and the header's name. *)
type listed = { tool : tool; mirrored : (string list * string) list }

type t = {
  client : Spindle_client.t;
  url : string;
  info : Value.t option;
  headers : (string * string) list;
  elicit : elicit option;
  rounds : int;
  oauth : Oauth.oauth option;
  next_id : int Atomic.t;
  listed : listed list option Atomic.t;
      (** the last list, for the headers a call mirrors *)
}

(* A question asked this many times is one no answer settles. *)
let default_rounds = 3

let create ?name ?version ?(headers = []) ?elicit ?(rounds = default_rounds)
    ?oauth client ~url =
  let info =
    match (name, version) with
    | Some n, Some v ->
        Some
          (Value.Object
             [ ("name", Value.String n); ("version", Value.String v) ])
    | _ -> None
  in
  {
    client;
    url;
    info;
    headers;
    elicit;
    rounds;
    oauth;
    next_id = Atomic.make 1;
    listed = Atomic.make None;
  }

type refusal = {
  status : Spindle_http.Status.t;
  code : int option;
  message : string;
}

type error =
  [ Spindle_client.error
  | `Refused of refusal
  | `Unreadable of string
  | `Unanswered of string
  | `Oauth of string ]

let error_to_string = function
  | #Spindle_client.error as e -> Spindle_client.error_to_string e
  | `Refused r ->
      Printf.sprintf "refused, %d%s: %s"
        (Spindle_http.Status.to_int r.status)
        (match r.code with Some c -> Printf.sprintf " (%d)" c | None -> "")
        r.message
  | `Unreadable why -> "an answer that is no MCP answer: " ^ why
  | `Unanswered why -> "a question left unanswered: " ^ why
  | `Oauth why -> "signing in failed: " ^ why
  | `Tool_failed why -> "the tool failed: " ^ why

let ( let* ) = Result.bind

let member name = function
  | Value.Object members -> List.assoc_opt name members
  | _ -> None

let string_member name v =
  match member name v with Some (Value.String s) -> Some s | _ -> None

(* streamable-http §Value Encoding: a value no plain ASCII header holds, or
   one that reads as the sentinel itself, is sent in Base64. *)
let header_value s =
  let n = String.length s in
  let plain =
    n > 0
    && String.for_all (fun c -> c >= ' ' && c <= '~') s
    && (not (Char.equal s.[0] ' '))
    && (not (Char.equal s.[n - 1] ' '))
    && not
         (String.starts_with ~prefix:"=?base64?" s
         && String.ends_with ~suffix:"?=" s)
  in
  if plain then s else "=?base64?" ^ Base64.encode_string s ^ "?="

(* The largest integer a double holds exactly, which an annotated integer
   stays within. *)
let safe_integer = 9007199254740991.

let mirrored_value = function
  | Value.String s -> Some s
  | Value.Bool b -> Some (if b then "true" else "false")
  | Value.Number f when Float.is_integer f && Float.abs f <= safe_integer ->
      Some (Printf.sprintf "%.0f" f)
  | _ -> None

let rec at path v =
  match path with
  | [] -> Some v
  | name :: rest -> Option.bind (member name v) (at rest)

(* The answer's JSON-RPC response: the body's, or the stream's event
   carrying it. *)
let response ~content_type body =
  let is_stream =
    match Option.map Media_type.parse content_type with
    | Some (Ok m) -> Media_type.matches "text/event-stream" m
    | Some (Error _) | None -> false
  in
  if not is_stream then Ok body
  else
    match Event_stream.feed (Event_stream.reader ()) (body ^ "\n\n") with
    | Error why -> Error (`Unreadable why)
    | Ok events -> (
        let is_response (e : Event_stream.event) =
          match Wiretype.decode Value.json e.data with
          | Ok v -> Option.is_some (member "id" v)
          | Error _ -> false
        in
        match List.find_opt is_response events with
        | Some e -> Ok e.data
        | None -> Error (`Unreadable "a stream that ended with no response"))

(* The bearer challenge's parameters, among an answer's [WWW-Authenticate]
   fields, read by their parser. *)
let bearer_challenge headers =
  List.concat_map
    (fun (name, value) ->
      if not (String.equal name "www-authenticate") then []
      else
        match Spindle_http.Auth.challenges value with
        | Ok challenges ->
            List.concat_map
              (fun (c : Spindle_http.Auth.t) ->
                match (c.scheme, c.value) with
                | "bearer", Params params -> params
                | _ -> [])
              challenges
        | Error _ -> [])
    headers

(* MCP's authorization: the token kept for the server goes with every
   request; a 401 signs in where its challenge says, and a 403 for a scope
   steps up to it, each retried once. *)
let exchange t ~headers ~body =
  let send () =
    let* bearer =
      match t.oauth with
      | None -> Ok []
      | Some o -> (
          match Oauth.access o ~resource:t.url with
          | Ok (Some token) -> Ok [ ("authorization", "Bearer " ^ token) ]
          | Ok None -> Ok []
          | Error e -> Error e)
    in
    Spindle_client.call t.client ~headers:(headers @ bearer) ~body `POST t.url
  in
  let* answer = send () in
  match t.oauth with
  | None -> Ok answer
  | Some o -> (
      let param n = List.assoc_opt n (bearer_challenge answer.headers) in
      let scopes =
        Option.map
          (fun s ->
            List.filter
              (fun x -> not (String.equal x ""))
              (String.split_on_char ' ' s))
          (param "scope")
      in
      let again () =
        let* (_ : Oauth.tokens) =
          Oauth.sign_in o ~resource:t.url
            ?metadata:(param "resource_metadata")
            ?scopes ()
        in
        send ()
      in
      match (answer.status, param "error") with
      | `Unauthorized, _ -> again ()
      | `Forbidden, Some "insufficient_scope" -> again ()
      | _ -> Ok answer)

let request t ~meth ?name ?(mirrored = []) params =
  let id = Atomic.fetch_and_add t.next_id 1 in
  let capabilities =
    Value.Object
      (match t.elicit with
      | Some _ -> [ ("elicitation", Value.Object []) ]
      | None -> [])
  in
  let meta =
    Value.Object
      ([
         ("io.modelcontextprotocol/protocolVersion", Value.String P.version);
         ("io.modelcontextprotocol/clientCapabilities", capabilities);
       ]
      @
      match t.info with
      | Some i -> [ ("io.modelcontextprotocol/clientInfo", i) ]
      | None -> [])
  in
  let body =
    Value.Object
      [
        ("jsonrpc", Value.String "2.0");
        ("id", Value.Number (float_of_int id));
        ("method", Value.String meth);
        ("params", Value.Object (params @ [ ("_meta", meta) ]));
      ]
  in
  let* text =
    Result.map_error
      (fun e -> `Unsent (Wiretype.Unwritable.to_string e))
      (Wiretype.encode Value.json body)
  in
  let headers =
    [
      ("content-type", "application/json");
      ("accept", "application/json, text/event-stream");
      ("mcp-protocol-version", P.version);
      ("mcp-method", meth);
    ]
    @ (match name with
      | Some n -> [ ("mcp-name", header_value n) ]
      | None -> [])
    @ List.map (fun (h, v) -> ("mcp-param-" ^ h, header_value v)) mirrored
    @ t.headers
  in
  let* answer = exchange t ~headers ~body:text in
  let content_type = List.assoc_opt "content-type" answer.headers in
  let refused code message =
    Error (`Refused { status = answer.status; code; message })
  in
  let json =
    Result.to_option
      (Result.bind (response ~content_type answer.body) (fun data ->
           Result.map_error
             (fun _ -> `Unreadable "no JSON")
             (Wiretype.decode Value.json data)))
  in
  match json with
  | Some v -> (
      match (member "error" v, member "result" v, member "id" v) with
      | Some e, _, _ ->
          refused
            (match member "code" e with
            | Some (Value.Number c) -> Some (int_of_float c)
            | _ -> None)
            (Option.value (string_member "message" e) ~default:"")
      | None, Some result, Some (Value.Number n)
        when Float.equal n (float_of_int id) ->
          Ok result
      | None, Some _, _ -> Error (`Unreadable "a response to another request")
      | None, None, _ ->
          (* A refusal of the server's own, an HTTP status and its words. *)
          refused None (Option.value (string_member "message" v) ~default:""))
  | None ->
      if Spindle_http.Status.to_int answer.status >= 400 then refused None ""
      else Error (`Unreadable "an answer that is no JSON-RPC response")

type server = {
  versions : string list;
  instructions : string option;
  name : string option;
  version : string option;
}

let discover t =
  let* r = request t ~meth:"server/discover" [] in
  let info =
    Option.bind (member "_meta" r) (member "io.modelcontextprotocol/serverInfo")
  in
  Ok
    {
      versions =
        (match member "supportedVersions" r with
        | Some (Value.Array l) ->
            List.filter_map (function Value.String s -> Some s | _ -> None) l
        | _ -> []);
      instructions = string_member "instructions" r;
      name = Option.bind info (string_member "name");
      version = Option.bind info (string_member "version");
    }

(* tools §x-mcp-header: an annotation on a property reached by [properties]
   alone, of a string, an integer or a boolean, its name a token unique
   without case; any other makes the tool one a client leaves out. *)
let mirrored_of schema =
  let rec count = function
    | Value.Object members ->
        List.fold_left
          (fun n (k, v) ->
            n + (if String.equal k "x-mcp-header" then 1 else 0) + count v)
          0 members
    | Value.Array l -> List.fold_left (fun n v -> n + count v) 0 l
    | _ -> 0
  in
  let is_tchar = function
    | 'A' .. 'Z'
    | 'a' .. 'z'
    | '0' .. '9'
    | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_'
    | '`' | '|' | '~' ->
        true
    | _ -> false
  in
  let rec walk path v =
    match member "properties" v with
    | Some (Value.Object props) ->
        List.concat_map
          (fun (name, p) ->
            let here = path @ [ name ] in
            let own =
              match member "x-mcp-header" p with
              | Some (Value.String h) -> [ (here, h, string_member "type" p) ]
              | Some _ -> [ (here, "", None) ]
              | None -> []
            in
            own @ walk here p)
          props
    | _ -> []
  in
  let found = walk [] schema in
  let ok (_, h, ty) =
    (not (String.equal h ""))
    && String.for_all is_tchar h
    &&
    match ty with
    | Some ("string" | "integer" | "boolean") -> true
    | _ -> false
  in
  let lowered = List.map (fun (_, h, _) -> String.lowercase_ascii h) found in
  let unique =
    List.length (List.sort_uniq String.compare lowered) = List.length lowered
  in
  if List.length found = count schema && List.for_all ok found && unique then
    Ok (List.map (fun (path, h, _) -> (path, h)) found)
  else Error "an x-mcp-header annotation 2026-07-28 does not allow"

let tool_of v =
  match (string_member "name" v, member "inputSchema" v) with
  | Some name, Some (Value.Object _ as input_schema) -> (
      let tool =
        {
          name;
          title = string_member "title" v;
          description = string_member "description" v;
          input_schema;
          output_schema = member "outputSchema" v;
        }
      in
      match mirrored_of input_schema with
      | Ok mirrored -> Some { tool; mirrored }
      | Error why ->
          L.warn (fun m -> m "the tool %S is left out: %s" name why);
          None)
  | _ ->
      L.warn (fun m ->
          m "a tool with no name or no object inputSchema is left out");
      None

let tools t =
  let rec pages seen cursor acc =
    let* r =
      request t ~meth:"tools/list"
        (match cursor with
        | Some c -> [ ("cursor", Value.String c) ]
        | None -> [])
    in
    let here =
      match member "tools" r with
      | Some (Value.Array l) -> List.filter_map tool_of l
      | _ -> []
    in
    match string_member "nextCursor" r with
    | None -> Ok (acc @ here)
    (* A cursor met before would page for ever. *)
    | Some c when List.exists (String.equal c) seen ->
        Error (`Unreadable "a cursor given twice")
    | Some c -> pages (c :: seen) (Some c) (acc @ here)
  in
  let* listed = pages [] None [] in
  Atomic.set t.listed (Some listed);
  Ok (List.map (fun l -> l.tool) listed)

type answer = { content : Value.t list; structured : Value.t option }

let reply_value = function
  | Accept content ->
      Value.Object [ ("action", Value.String "accept"); ("content", content) ]
  | Decline -> Value.Object [ ("action", Value.String "decline") ]
  | Cancel -> Value.Object [ ("action", Value.String "cancel") ]

(* mrtr §Client Requirements: each question answered, for the retry. *)
let answers t questions =
  match t.elicit with
  | None ->
      Error (`Unanswered "the server asked, and this client declared no elicit")
  | Some elicit ->
      List.fold_right
        (fun (key, q) acc ->
          let* acc = acc in
          match string_member "method" q with
          | Some "elicitation/create" ->
              let params =
                Option.value (member "params" q) ~default:(Value.Object [])
              in
              let message =
                Option.value (string_member "message" params) ~default:""
              in
              let schema =
                Option.value
                  (member "requestedSchema" params)
                  ~default:(Value.Object [])
              in
              Ok ((key, reply_value (elicit ~message ~schema)) :: acc)
          | _ ->
              Error
                (`Unanswered "a question of a kind this client answers none of"))
        questions (Ok [])

let mirrored_for t name arguments =
  match Atomic.get t.listed with
  | None -> []
  | Some listed -> (
      match List.find_opt (fun l -> String.equal l.tool.name name) listed with
      | None -> []
      | Some l ->
          List.filter_map
            (fun (path, h) ->
              Option.map
                (fun v -> (h, v))
                (Option.bind (at path arguments) mirrored_value))
            l.mirrored)

let call_value t name arguments =
  let rec attempt ~round ~relisted extra =
    let r =
      request t ~meth:"tools/call" ~name
        ~mirrored:(mirrored_for t name arguments)
        ([ ("name", Value.String name); ("arguments", arguments) ] @ extra)
    in
    match r with
    (* streamable-http §Client Behavior: a header the server wants and this
       client did not send means the tool changed; list it again, once. *)
    | Error (`Refused { code = Some c; _ })
      when c = P.Code.header_mismatch && not relisted ->
        let* (_ : tool list) = tools t in
        attempt ~round ~relisted:true extra
    | Error e -> Error e
    | Ok result -> (
        match string_member "resultType" result with
        | Some "input_required" ->
            if round >= t.rounds then
              Error
                (`Unanswered
                   (Printf.sprintf "still asking after %d rounds" round))
            else
              let questions =
                match member "inputRequests" result with
                | Some (Value.Object qs) -> qs
                | _ -> []
              in
              let* responses = answers t questions in
              let state =
                match member "requestState" result with
                | Some s -> [ ("requestState", s) ]
                | None -> []
              in
              attempt ~round:(round + 1) ~relisted
                ([ ("inputResponses", Value.Object responses) ] @ state)
        (* basic §ResultType: one from an earlier server, which has none,
           is complete. *)
        | Some "complete" | None -> (
            let content =
              match member "content" result with
              | Some (Value.Array l) -> l
              | _ -> []
            in
            match member "isError" result with
            | Some (Value.Bool true) ->
                Error
                  (`Tool_failed
                     (String.concat "\n"
                        (List.filter_map (string_member "text") content)))
            | _ ->
                Ok { content; structured = member "structuredContent" result })
        | Some other -> Error (`Unreadable ("a resultType of " ^ other)))
  in
  attempt ~round:0 ~relisted:false []

let call t name arguments value result =
  let* args =
    Result.map_error
      (fun e -> `Unsent (Wiretype.Unwritable.to_string e))
      (Wiretype.to_value arguments value)
  in
  let* a = call_value t name args in
  match a.structured with
  | None -> Error (`Unreadable "no structuredContent")
  | Some v ->
      Result.map_error
        (fun problems ->
          `Unreadable
            (String.concat "; " (List.map Wiretype.Problem.to_string problems)))
        (Wiretype.of_value result v)
