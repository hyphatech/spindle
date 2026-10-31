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

type progress = {
  progress : float;
  total : float option;
  message : string option;
}

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
   steps up to it, each retried once. [head] is an answer's status and
   headers, where it is one a sign-in could change. *)
let authorized t ~headers ~head send =
  let attempt () =
    let* bearer =
      match t.oauth with
      | None -> Ok []
      | Some o -> (
          match Oauth.access o ~resource:t.url with
          | Ok (Some token) -> Ok [ ("authorization", "Bearer " ^ token) ]
          | Ok None -> Ok []
          | Error e -> Error e)
    in
    send (headers @ bearer)
  in
  let* answer = attempt () in
  match (t.oauth, head answer) with
  | None, _ | _, None -> Ok answer
  | Some o, Some (status, answer_headers) -> (
      let param n = List.assoc_opt n (bearer_challenge answer_headers) in
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
        attempt ()
      in
      match (status, param "error") with
      | `Unauthorized, _ -> again ()
      | `Forbidden, Some "insufficient_scope" -> again ()
      | _ -> Ok answer)

let exchange ?on_event t ~headers ~body =
  authorized t ~headers
    ~head:(fun (a : string Spindle_client.response) ->
      Some (a.status, a.headers))
    (fun headers ->
      match on_event with
      | None -> Spindle_client.call t.client ~headers ~body `POST t.url
      (* Each event handed on as it arrives, and the whole kept for the
         answer's reading, as {!Spindle_client.call} would give it. *)
      | Some on_event ->
          Result.join
            (Spindle_client.stream t.client ~headers ~body `POST t.url
               (fun (answer : Spindle_client.Body.t Spindle_client.response) ->
                 let whole = Buffer.create 256
                 and reader = Event_stream.reader () in
                 let rec read () =
                   match Spindle_client.Body.read answer.body with
                   | Ok (`Data d) ->
                       Buffer.add_string whole d;
                       (match Event_stream.feed reader d with
                       | Ok events -> List.iter on_event events
                       | Error _ -> ());
                       read ()
                   | Ok `End -> Ok { answer with body = Buffer.contents whole }
                   | Error e -> Error e
                 in
                 read ())))

(* A request's id, the headers 2026-07-28 asks for, and its body. *)
let message ?progress_token t ~meth ?name ?(mirrored = []) params =
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
      @ (match t.info with
        | Some i -> [ ("io.modelcontextprotocol/clientInfo", i) ]
        | None -> [])
      @
      match progress_token with
      | Some token -> [ ("progressToken", token id) ]
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
  Ok (id, headers, text)

let request ?progress t ~meth ?name ?mirrored params =
  let token id = Value.String ("progress-" ^ string_of_int id) in
  let* id, headers, text =
    message
      ?progress_token:(Option.map (fun _ -> token) progress)
      t ~meth ?name ?mirrored params
  in
  let token = token id in
  (* progress §Progress Flow: a report naming this call's token is told the
     caller; any other event is the answer's, or not this call's. *)
  let on_event =
    Option.map
      (fun tell (e : Event_stream.event) ->
        match Wiretype.decode Value.json e.data with
        | Ok v -> (
            match (string_member "method" v, member "params" v) with
            | Some "notifications/progress", Some p
              when Option.equal Value.equal (member "progressToken" p)
                     (Some token) -> (
                match member "progress" p with
                | Some (Value.Number progress) ->
                    tell
                      {
                        progress;
                        total =
                          (match member "total" p with
                          | Some (Value.Number n) -> Some n
                          | _ -> None);
                        message = string_member "message" p;
                      }
                | _ -> ())
            | _ -> ())
        | Error _ -> ())
      progress
  in
  let* answer = exchange ?on_event t ~headers ~body:text in
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

(* pagination: every page of a list, each item of [key] read by [item]. *)
let pages t ~meth ~key item =
  let rec page seen cursor acc =
    let* r =
      request t ~meth
        (match cursor with
        | Some c -> [ ("cursor", Value.String c) ]
        | None -> [])
    in
    let here =
      match member key r with
      | Some (Value.Array l) -> List.filter_map item l
      | _ -> []
    in
    match string_member "nextCursor" r with
    | None -> Ok (acc @ here)
    (* A cursor met before would page for ever. *)
    | Some c when List.exists (String.equal c) seen ->
        Error (`Unreadable "a cursor given twice")
    | Some c -> page (c :: seen) (Some c) (acc @ here)
  in
  page [] None []

let tools t =
  let* listed = pages t ~meth:"tools/list" ~key:"tools" tool_of in
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

let call_value ?progress t name arguments =
  let rec attempt ~round ~relisted extra =
    let r =
      request ?progress t ~meth:"tools/call" ~name
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

let call ?progress t name arguments value result =
  let* args =
    Result.map_error
      (fun e -> `Unsent (Wiretype.Unwritable.to_string e))
      (Wiretype.to_value arguments value)
  in
  let* a = call_value ?progress t name args in
  match a.structured with
  | None -> Error (`Unreadable "no structuredContent")
  | Some v ->
      Result.map_error
        (fun problems ->
          `Unreadable
            (String.concat "; " (List.map Wiretype.Problem.to_string problems)))
        (Wiretype.of_value result v)

type resource = {
  uri : string;
  name : string;
  title : string option;
  description : string option;
  mime : string option;
}

type template = {
  uri_template : string;
  name : string;
  title : string option;
  description : string option;
  mime : string option;
}

type data = Text of string | Blob of string
type content = { uri : string; mime : string option; data : data }

let resources t =
  pages t ~meth:"resources/list" ~key:"resources" (fun v ->
      match (string_member "uri" v, string_member "name" v) with
      | Some uri, Some name ->
          Some
            {
              uri;
              name;
              title = string_member "title" v;
              description = string_member "description" v;
              mime = string_member "mimeType" v;
            }
      | _ ->
          L.warn (fun m -> m "a resource with no uri or no name is left out");
          None)

let templates t =
  pages t ~meth:"resources/templates/list" ~key:"resourceTemplates" (fun v ->
      match (string_member "uriTemplate" v, string_member "name" v) with
      | Some uri_template, Some name ->
          Some
            {
              uri_template;
              name;
              title = string_member "title" v;
              description = string_member "description" v;
              mime = string_member "mimeType" v;
            }
      | _ ->
          L.warn (fun m ->
              m "a template with no uriTemplate or no name is left out");
          None)

(* resources §Reading Resources: each content text or base64 bytes. *)
let content_of v =
  let uri = Option.value (string_member "uri" v) ~default:"" in
  let mime = string_member "mimeType" v in
  match (string_member "text" v, string_member "blob" v) with
  | Some text, _ -> Ok { uri; mime; data = Text text }
  | None, Some blob -> (
      match Base64.decode blob with
      | Ok bytes -> Ok { uri; mime; data = Blob bytes }
      | Error _ -> Error (`Unreadable "a blob that is no base64"))
  | None, None -> Error (`Unreadable "a content with no text and no blob")

let read t uri =
  let* r =
    request t ~meth:"resources/read" ~name:uri [ ("uri", Value.String uri) ]
  in
  match member "contents" r with
  | Some (Value.Array contents) ->
      List.fold_right
        (fun v acc ->
          let* rest = acc in
          let* c = content_of v in
          Ok (c :: rest))
        contents (Ok [])
  | _ -> Error (`Unreadable "a read with no contents")

type notification = Acknowledged of string list | Updated of string
type ended = Stopped | Completed | Dropped of string

(* Four of a Spindle server's keep-alives, so a quiet stream is never taken
   for a lost one. *)
let listen_read_timeout = Mtime.Span.(60 * s)

(* How the stream's reading came out, before it is an end or an error. *)
type listened =
  | Ended of ended
  | Refused_with of string Spindle_client.response
  | Failed of error

let listen ?(read_timeout = listen_read_timeout) t uris f =
  let* id, headers, text =
    message t ~meth:"subscriptions/listen"
      [
        ( "notifications",
          Value.Object
            [
              ( "resourceSubscriptions",
                Value.Array (List.map (fun u -> Value.String u) uris) );
            ] );
      ]
  in
  let ours v =
    Option.equal Value.equal
      (at [ "_meta"; "io.modelcontextprotocol/subscriptionId" ] v)
      (Some (Value.Number (float_of_int id)))
  in
  let is_stream (answer : _ Spindle_client.response) =
    match
      Option.map Media_type.parse (List.assoc_opt "content-type" answer.headers)
    with
    | Some (Ok m) ->
        Media_type.matches "text/event-stream" m
        && Spindle_http.Status.to_int answer.status = 200
    | Some (Error _) | None -> false
  in
  (* subscriptions §Opening a Stream: the acknowledgment first, then each
     change; the response to the listen is the server ending it. *)
  let rec read (answer : Spindle_client.Body.t Spindle_client.response) reader
      acknowledged =
    match Spindle_client.Body.read answer.body with
    | Ok (`Data d) -> (
        match Event_stream.feed reader d with
        | Error why -> Failed (`Unreadable why)
        | Ok events -> each answer reader acknowledged events)
    | Ok `End ->
        if acknowledged then Ended (Dropped "the stream ended with no result")
        else Failed (`Lost "the stream ended before it was acknowledged")
    | Error e ->
        if acknowledged then Ended (Dropped (Spindle_client.error_to_string e))
        else Failed (e :> error)
  and each answer reader acknowledged = function
    | [] -> read answer reader acknowledged
    | (e : Event_stream.event) :: rest -> (
        let v = Result.to_option (Wiretype.decode Value.json e.data) in
        let params = Option.bind v (member "params") in
        let tell n k =
          match f n with `Continue -> k () | `Stop -> Ended Stopped
        in
        match
          ( Option.bind v (string_member "method"),
            Option.bind v (member "id"),
            Option.bind v (member "result") )
        with
        | _, Some (Value.Number n), Some _ when Float.equal n (float_of_int id)
          ->
            Ended Completed
        | Some "notifications/subscriptions/acknowledged", _, _
          when (not acknowledged) && Option.fold ~none:false ~some:ours params
          ->
            let honoured =
              match
                Option.bind params
                  (at [ "notifications"; "resourceSubscriptions" ])
              with
              | Some (Value.Array l) ->
                  List.filter_map
                    (function Value.String u -> Some u | _ -> None)
                    l
              | _ -> []
            in
            tell (Acknowledged honoured) (fun () ->
                each answer reader true rest)
        | Some "notifications/resources/updated", _, _
          when acknowledged && Option.fold ~none:false ~some:ours params -> (
            match Option.bind params (string_member "uri") with
            | Some uri ->
                tell (Updated uri) (fun () -> each answer reader true rest)
            | None -> each answer reader acknowledged rest)
        | _ ->
            L.warn (fun m ->
                m "a listen's message that is not its own is dropped: %s"
                  (Option.value ~default:"no method"
                     (Option.bind v (string_member "method"))));
            each answer reader acknowledged rest)
  in
  let* listened =
    authorized t ~headers
      ~head:(function
        | Refused_with (a : string Spindle_client.response) ->
            Some (a.status, a.headers)
        | Ended _ | Failed _ -> None)
      (fun headers ->
        Spindle_client.stream t.client ~read_timeout ~headers ~body:text `POST
          t.url (fun answer ->
            if is_stream answer then read answer (Event_stream.reader ()) false
            else
              (* The answer whole, as a refusal is read. *)
              let whole = Buffer.create 256 in
              let rec drain () =
                match Spindle_client.Body.read answer.body with
                | Ok (`Data d) ->
                    Buffer.add_string whole d;
                    drain ()
                | Ok `End ->
                    Refused_with { answer with body = Buffer.contents whole }
                | Error e -> Failed (e :> error)
              in
              drain ()))
  in
  match listened with
  | Ended e -> Ok e
  | Failed e -> Error (e : error :> [> error ])
  | Refused_with answer -> (
      let refused code message =
        Error (`Refused { status = answer.status; code; message })
      in
      match Result.to_option (Wiretype.decode Value.json answer.body) with
      | Some v -> (
          match member "error" v with
          | Some e ->
              refused
                (match member "code" e with
                | Some (Value.Number c) -> Some (int_of_float c)
                | _ -> None)
                (Option.value (string_member "message" e) ~default:"")
          | None ->
              refused None
                (Option.value (string_member "message" v) ~default:""))
      | None -> refused None "")
