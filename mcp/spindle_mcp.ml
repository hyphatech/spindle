module P = Spindle_mcp_protocol
module Dep = Spindle.Dep
module Bearer = Spindle.Bearer
module Value = Wiretype.Value
module Schema = Wiretype.Schema
open Spindle.Syntax

(* elicitation §Requested Schema: a form is a flat object, each member a
   string, a number, an integer, a boolean or an enum, written in place. *)
let form_schema ~at description =
  let ctx = Schema.create () in
  let root = Schema.walk ctx Schema.Decode ~at description in
  let components = Schema.components ctx in
  let resolved = function
    | Schema.Ref name -> (
        match List.assoc_opt (Schema.name_of_kind name) components with
        | Some s -> s
        | None -> Schema.Ref name)
    | s -> s
  in
  let rec primitive = function
    | Schema.String _ | Schema.Number _ | Schema.Integer _ | Schema.Boolean ->
        true
    | Schema.Described { schema; _ } -> primitive schema
    | _ -> false
  in
  match resolved root with
  | Schema.Object o ->
      let props =
        List.map
          (fun (p : Schema.prop) -> { p with schema = resolved p.schema })
          o.props
      in
      if List.for_all (fun (p : Schema.prop) -> primitive p.schema) props then
        Ok (Schema.Json_schema.of_t (Schema.Object { o with props }))
      else Error "an object holding no more than strings, numbers and booleans"
  | _ -> Error "an object"

module Question = struct
  type 'a t = {
    key : string;
    message : string;
    answer : 'a Wiretype.t;
    form : (Value.t, string) result;
  }

  type declared = Declared : 'a t -> declared

  let form key ~message answer =
    { key; message; answer; form = form_schema ~at:key answer }

  let declare q = Declared q
end

type 'a reply = Accept of 'a | Decline | Cancel

(* elicitation §Response Actions: what a person did with a question; an
   accepted answer that does not read is no answer. *)
let replied (q : 'a Question.t) response =
  match
    (P.member "action" (Some response), P.member "content" (Some response))
  with
  | Some (Value.String "accept"), Some content -> (
      match Wiretype.of_value q.answer content with
      | Ok a -> Some (Accept a)
      | Error _ -> None)
  | Some (Value.String "decline"), _ -> Some Decline
  | Some (Value.String "cancel"), _ -> Some Cancel
  | _ -> None

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
  asks : Question.declared list;
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

let tool ?title ?doc ?scope ?(asks = []) name arguments result f =
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
    asks;
    (* Every tool's dependency is read on every call, so its refusal is
       this tool's error, and no other's. *)
    run =
      Dep.map
        (function
          | Ok f -> call f
          | Error (refusal : Spindle.Refusal.t) ->
              fun _ -> Failed refusal.message)
        (Dep.attempt f);
  }

type content = Text of string | Blob of string

module Template = struct
  type 'a t = {
    names : string list;
    read : (string * string) list -> ('a, string list) result;
  }

  let of_text name description text =
    Result.map_error
      (List.map (fun p -> name ^ ": " ^ Wiretype.Problem.to_string p))
      (Wiretype.of_text description text)

  let required name description =
    {
      names = [ name ];
      read =
        (fun variables ->
          match List.assoc_opt name variables with
          | Some text -> of_text name description text
          | None -> Error [ name ^ ": missing" ]);
    }

  let optional name description =
    {
      names = [ name ];
      read =
        (fun variables ->
          match List.assoc_opt name variables with
          | Some text -> Result.map Option.some (of_text name description text)
          | None -> Ok None);
    }

  let ( let+ ) t f = { t with read = (fun v -> Result.map f (t.read v)) }

  let ( and+ ) a b =
    {
      names = a.names @ b.names;
      read =
        (fun v ->
          match (a.read v, b.read v) with
          | Ok x, Ok y -> Ok (x, y)
          | Error e, Ok _ | Ok _, Error e -> Error e
          | Error e, Error f -> Error (e @ f));
    }
end

(* A template, as far as RFC 6570 reads back: literals, level 1's [{name}],
   and level 3's form-style query, last. *)
type part = Literal of string | Variable of string | Query of string list

let is_varname s =
  String.length s > 0
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '.' -> true | _ -> false)
       s

let parse_template text =
  let n = String.length text in
  let literal acc start stop =
    if stop > start then Literal (String.sub text start (stop - start)) :: acc
    else acc
  in
  let rec walk start i acc =
    if i >= n then Ok (List.rev (literal acc start i))
    else
      match text.[i] with
      | '}' -> Error "a '}' that closes nothing"
      | '{' -> (
          match String.index_from_opt text i '}' with
          | None -> Error "a '{' never closed"
          | Some j -> (
              let inner = String.sub text (i + 1) (j - i - 1) in
              let next part =
                walk (j + 1) (j + 1) (part :: literal acc start i)
              in
              match inner with
              | "" -> Error "an empty expression"
              | _ when Char.equal inner.[0] '?' ->
                  let names =
                    String.split_on_char ','
                      (String.sub inner 1 (String.length inner - 1))
                  in
                  if List.for_all is_varname names then next (Query names)
                  else Error ("{" ^ inner ^ "}, which is no form-style query")
              | _ when is_varname inner -> next (Variable inner)
              | _ ->
                  Error
                    ("{" ^ inner
                   ^ "}, an expression beyond level 1 and a form-style query")))
      | _ -> walk start (i + 1) acc
  in
  match walk 0 0 [] with
  | Error _ as e -> e
  | Ok parts ->
      let rec check = function
        | Variable _ :: Variable _ :: _ -> Error "two variables side by side"
        | Query _ :: _ :: _ -> Error "a query that is not last"
        | _ :: rest -> check rest
        | [] -> Ok parts
      in
      check parts

(* RFC 3986 §2.1: each %XX its byte; a % not followed by two hex digits is
   itself. *)
let percent_decoded s =
  let n = String.length s in
  let b = Buffer.create n in
  let hex c =
    match c with
    | '0' .. '9' -> Some (Char.code c - 48)
    | 'a' .. 'f' -> Some (Char.code c - 87)
    | 'A' .. 'F' -> Some (Char.code c - 55)
    | _ -> None
  in
  let rec go i =
    if i < n then
      match (s.[i], i + 2 < n) with
      | '%', true -> (
          match (hex s.[i + 1], hex s.[i + 2]) with
          | Some h, Some l ->
              Buffer.add_char b (Char.chr ((h * 16) + l));
              go (i + 3)
          | _ ->
              Buffer.add_char b '%';
              go (i + 1))
      | c, _ ->
          Buffer.add_char b c;
          go (i + 1)
  in
  go 0;
  Buffer.contents b

(* The variables a URI holds, where the template matches it. A variable runs
   up to the next literal, never across [/], [?] or [#]. *)
let matched parts uri =
  let path, query =
    match List.rev parts with
    | Query names :: _ -> (
        match String.index_opt uri '?' with
        | Some i ->
            ( String.sub uri 0 i,
              List.filter
                (fun (k, _) -> List.mem k names)
                (Spindle_http.Urlencoded.parse
                   (String.sub uri (i + 1) (String.length uri - i - 1))) )
        | None -> (uri, []))
    | _ -> (uri, [])
  in
  let n = String.length path in
  let at i l =
    i + String.length l <= n
    && String.equal (String.sub path i (String.length l)) l
  in
  let free c = not (Char.equal c '/' || Char.equal c '?' || Char.equal c '#') in
  let rec go i acc = function
    | [] | [ Query _ ] -> if i = n then Some (List.rev acc) else None
    | Query _ :: _ -> None
    | Literal l :: rest ->
        if at i l then go (i + String.length l) acc rest else None
    | Variable v :: rest ->
        let ends j = match rest with Literal l :: _ -> at j l | _ -> j = n in
        let rec stop j =
          if j > i && ends j then Some j
          else if j < n && free path.[j] then stop (j + 1)
          else None
        in
        Option.bind (stop i) (fun j ->
            go j ((v, percent_decoded (String.sub path i (j - i))) :: acc) rest)
  in
  if String.contains uri '#' then None
  else Option.map (fun variables -> variables @ query) (go 0 [] parts)

type located =
  | Fixed of string
  | Templated of {
      text : string;
      parts : (part list, string) result;
      names : string list;
    }

(* What a read of one resource came to. *)
type reading =
  | Read of content list
  | Not_found
  | Unreadable of string list  (** its variables *)
  | Refused of Spindle.Refusal.t  (** by its dependency, not of an object *)
  | Failed of string  (** its function's other refusal: the sentence *)

type resource = {
  uri : located;
  name : string;
  title : string option;
  doc : string option;
  mime : string option;
  scope : string option;
  ttl_ms : int option;
  codes : Spindle.Refusal.Code.t list;
  read : ((string * string) list -> reading) Dep.t;
}

(* Someone else's object is read as a missing one, so a read reveals no more
   than a listen does. *)
let hidden (refusal : Spindle.Refusal.t) =
  Spindle.Refusal.Code.equal refusal.code Spindle.Refusal.Code.not_found
  || Spindle.Refusal.Code.equal refusal.code Spindle.Access.forbidden

let reading f variables_of =
  Dep.map
    (function
      | Error refusal ->
          fun _ -> if hidden refusal then Not_found else Refused refusal
      | Ok f -> (
          fun variables ->
            match variables_of variables with
            | Error problems -> Unreadable problems
            | Ok v -> (
                match f v with
                | Ok contents -> Read contents
                | Error refusal when hidden refusal -> Not_found
                | Error (refusal : Spindle.Refusal.t) -> Failed refusal.message)
          ))
    (Dep.attempt f)

let resource ?title ?doc ?mime ?scope ?ttl_ms uri ~name f =
  {
    uri = Fixed uri;
    name;
    title;
    doc;
    mime;
    scope;
    ttl_ms;
    codes = Dep.codes f;
    read = reading f (fun _ -> Ok ());
  }

let template ?title ?doc ?mime ?scope ?ttl_ms text ~name
    (variables : 'v Template.t) f =
  {
    uri =
      Templated { text; parts = parse_template text; names = variables.names };
    name;
    title;
    doc;
    mime;
    scope;
    ttl_ms;
    codes = Dep.codes f;
    read = reading f variables.read;
  }

(* The variables of [uri], where [r] is the resource it names. *)
let names_it (r : resource) uri =
  match r.uri with
  | Fixed u -> if String.equal u uri then Some [] else None
  | Templated { parts = Ok parts; _ } -> matched parts uri
  | Templated { parts = Error _; _ } -> None

module Changes = struct
  type t = (unit, string) Spindle.Broadcast.t

  let create ?depth () = Spindle.Broadcast.create ?depth ()
  let updated t uri = Spindle.Broadcast.publish t ~topic:uri uri
  let watched t = Spindle.Broadcast.topics t
  let close = Spindle.Broadcast.close
end

let src = Logs.Src.create "spindle-mcp" ~doc:"An MCP server's calls"

module L = (val Logs.src_log src : Logs.LOG)

(* What a call's stream sends: a report as it is made, then the answer. *)
type note = Report of string | Answer of string

type call = {
  token : Value.t option;  (** the client's [progressToken], if it asked *)
  responses : (string * Value.t) list;
      (** the [inputResponses] a call made again carries, by question *)
  notes : note Eio.Stream.t;
  last : float Atomic.t;  (** the last report sent *)
}

(* A tool reporting faster than the client reads waits once this many are
   unsent. *)
let unsent_reports = 16

let call =
  Dep.map
    (fun body ->
      let params =
        match P.read body with
        | Ok (Request { params; _ }) -> params
        | Ok (Notification _) | Error _ -> None
      in
      {
        token = P.member "progressToken" (P.member "_meta" params);
        responses =
          (match P.member "inputResponses" params with
          | Some (Value.Object r) -> r
          | _ -> []);
        notes = Eio.Stream.create unsent_reports;
        last = Atomic.make Float.neg_infinity;
      })
    Spindle.body

let answer (c : call) (q : 'a Question.t) =
  match Option.bind (List.assoc_opt q.key c.responses) (replied q) with
  | Some r -> r
  | None -> Cancel

let answered (c : call) (Question.Declared q) =
  Option.is_some (Option.bind (List.assoc_opt q.key c.responses) (replied q))

let progress (c : call) ?total ?message done_ =
  match c.token with
  | None -> ()
  | Some token ->
      (* progress §Requirements: each report larger than the last. *)
      let rec claim () =
        let last = Atomic.get c.last in
        if done_ <= last then false
        else if Atomic.compare_and_set c.last last done_ then true
        else claim ()
      in
      if claim () then
        Eio.Stream.add c.notes
          (Report
             (P.notification "notifications/progress"
                ([ ("progressToken", token); ("progress", Value.Number done_) ]
                @ (match total with
                  | Some t -> [ ("total", Value.Number t) ]
                  | None -> [])
                @
                match message with
                | Some m -> [ ("message", Value.String m) ]
                | None -> [])))

(* tools §Tool Names: what a name SHOULD be, held as a MUST, since a name is
   written in source. *)
let max_name = 128

(* Each URI a listen watches is a read as it opens, and a subscription and a
   fiber for as long as it lasts; this many bound what one request holds. *)
let max_subscriptions = 64

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
      List.iteri
        (fun j (Question.Declared q) ->
          (match q.form with
          | Error why ->
              refuse (Printf.sprintf "%S asks %S for %s" t.name q.key why)
          | Ok _ -> ());
          if
            List.exists
              (fun (Question.Declared r) -> String.equal r.key q.key)
              (List.filteri (fun k _ -> k < j) t.asks)
          then
            refuse
              (Printf.sprintf "%S asks two questions keyed %S" t.name q.key))
        t.asks)
    tools

let check_resources ~auth resources =
  let twice l =
    List.exists (fun x -> List.length (List.filter (String.equal x) l) > 1) l
  in
  List.iteri
    (fun i (r : resource) ->
      let earlier = List.filteri (fun j _ -> j < i) resources in
      (match r.uri with
      | Fixed uri ->
          if
            List.exists
              (fun (e : resource) ->
                match e.uri with
                | Fixed u -> String.equal u uri
                | Templated _ -> false)
              earlier
          then refuse (Printf.sprintf "two resources are at %S" uri)
      | Templated { text; parts; names } -> (
          if
            List.exists
              (fun (e : resource) ->
                match e.uri with
                | Templated t -> String.equal t.text text
                | Fixed _ -> false)
              earlier
          then refuse (Printf.sprintf "two templates are %S" text);
          match parts with
          | Error why -> refuse (Printf.sprintf "%S holds %s" text why)
          | Ok parts ->
              let named =
                List.concat_map
                  (function
                    | Variable v -> [ v ] | Query vs -> vs | Literal _ -> [])
                  parts
              in
              if twice named then
                refuse (Printf.sprintf "%S names a variable twice" text);
              if twice names then
                refuse (Printf.sprintf "%S reads a variable twice" text);
              List.iter
                (fun v ->
                  if not (List.mem v names) then
                    refuse
                      (Printf.sprintf "%S names %S, which it does not read" text
                         v))
                named;
              List.iter
                (fun v ->
                  if not (List.mem v named) then
                    refuse
                      (Printf.sprintf "%S reads %S, which it does not name" text
                         v))
                names));
      match (r.scope, auth) with
      | Some _, None ->
          refuse
            (Printf.sprintf "%S needs a scope, and no auth is given" r.name)
      | _ -> ())
    resources

let opt name = function Some v -> [ (name, Value.String v) ] | None -> []

(* resources §Reading Resources: each content with the URI read. *)
let content_value uri mime content =
  Value.Object
    ([ ("uri", Value.String uri) ]
    @ opt "mimeType" mime
    @
    match content with
    | Text t -> [ ("text", Value.String t) ]
    | Blob b -> [ ("blob", Value.String (Base64.encode_string b)) ])

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
    ?(ttl_ms = 300_000) ?(resources = []) ?changes ~name ~version tools =
  check ~auth tools;
  check_resources ~auth resources;
  let served =
    Value.Object
      [ ("name", Value.String name); ("version", Value.String version) ]
  in
  let result_meta =
    ("_meta", Value.Object [ ("io.modelcontextprotocol/serverInfo", served) ])
  in
  (* caching §Cache Scope: a list filtered by the token is the token's. *)
  let cached ttl_ms =
    [
      ("ttlMs", Value.Number (float_of_int ttl_ms));
      ( "cacheScope",
        Value.String (match auth with Some _ -> "private" | None -> "public") );
    ]
  in
  let cacheable = cached ttl_ms in
  let scopes =
    List.fold_left
      (fun acc scope ->
        match scope with
        | Some s when not (List.exists (String.equal s) acc) -> acc @ [ s ]
        | Some _ | None -> acc)
      []
      (List.map (fun (t : tool) -> t.scope) tools
      @ List.map (fun (r : resource) -> r.scope) resources)
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
  (* A URI is read by a resource at it before any template. *)
  let reads =
    List.fold_right
      (fun (r : resource) acc ->
        Dep.map (fun (f, rest) -> (r, f) :: rest) (Dep.both r.read acc))
      (List.filter
         (fun (r : resource) ->
           match r.uri with Fixed _ -> true | Templated _ -> false)
         resources
      @ List.filter
          (fun (r : resource) ->
            match r.uri with Fixed _ -> false | Templated _ -> true)
          resources)
      (Dep.return [])
  in
  let header h = Spindle.Header.optional h Wiretype.string in
  let granted scope (claims : Bearer.claims option) =
    match (scope, claims) with
    | Some s, Some c -> List.exists (String.equal s) c.scopes
    | Some _, None | None, _ -> true
  in
  let grants (t : tool) claims = granted t.scope claims in
  let answer ~id ~meth ~params ~claims ~runs ~reads ~gone ~(call : call) =
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
             ( "capabilities",
               Value.Object
                 (("tools", Value.Object [])
                 ::
                 (match (resources, changes) with
                 | [], None -> []
                 | _, Some _ ->
                     [
                       ( "resources",
                         Value.Object [ ("subscribe", Value.Bool true) ] );
                     ]
                 | _ :: _, None -> [ ("resources", Value.Object []) ])) );
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
        (* mrtr §Basic Workflow: a question unanswered, or answered so it
           does not read, is asked again, every one in one round, before the
           tool runs. *)
        | Some (t, _) when List.exists (fun q -> not (answered call q)) t.asks
          ->
            let unanswered =
              List.filter (fun q -> not (answered call q)) t.asks
            in
            (* mrtr §Server Requirements 7: a client is asked only what it said
               it answers; [elicitation: {}] is a form, as it was before modes
               were named. *)
            let forms =
              match
                P.member "elicitation"
                  (P.member "io.modelcontextprotocol/clientCapabilities"
                     (P.member "_meta" params))
              with
              | Some (Value.Object modes) ->
                  List.mem_assoc "form" modes
                  || not (List.mem_assoc "url" modes)
              | _ -> false
            in
            if not forms then
              json ~status:`Bad_request
                (P.error ~id
                   ~data:
                     (Value.Object
                        [
                          ( "requiredCapabilities",
                            Value.Object
                              [
                                ( "elicitation",
                                  Value.Object [ ("form", Value.Object []) ] );
                              ] );
                        ])
                   P.Code.missing_capability
                   "Missing required client capability")
            else
              ok
                [
                  ("resultType", Value.String "input_required");
                  ( "inputRequests",
                    Value.Object
                      (List.map
                         (fun (Question.Declared q) ->
                           ( q.key,
                             Value.Object
                               [
                                 ("method", Value.String "elicitation/create");
                                 ( "params",
                                   Value.Object
                                     [
                                       ("mode", Value.String "form");
                                       ("message", Value.String q.message);
                                       ( "requestedSchema",
                                         match q.form with
                                         | Ok s -> s
                                         | Error _ -> Value.Null );
                                     ] );
                               ] ))
                         unanswered) );
                ]
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
            let finished () =
              match run arguments with
              | Answered { structured; text } ->
                  Ok
                    (P.result id
                       [
                         complete;
                         content text;
                         ("structuredContent", structured);
                         ("isError", Value.Bool false);
                         result_meta;
                       ])
              | Failed why ->
                  Ok
                    (P.result id
                       [
                         complete;
                         content why;
                         ("isError", Value.Bool true);
                         result_meta;
                       ])
              | Broken why -> Error why
            in
            match call.token with
            | None -> (
                match finished () with
                | Ok text -> json text
                | Error why -> Error (Spindle.Refusal.internal ~detail:why))
            (* streamable-http §Receiving Messages: the reports the client asked
               for, then the answer, which ends the stream. *)
            | Some _ ->
                let event data =
                  match Spindle_http.Event_stream.event data with
                  | Ok e -> e
                  | Error _ -> ""
                in
                Ok
                  (Spindle.Response.stream ~content_type:"text/event-stream"
                     ~headers:[ ("x-accel-buffering", "no") ]
                     (fun send ->
                       Eio.Fiber.both
                         (fun () ->
                           let text =
                             match finished () with
                             | Ok text -> text
                             | Error why ->
                                 (* The head has gone, so the bug is told as
                                    JSON-RPC's own, and here. *)
                                 L.err (fun m ->
                                     m
                                       "a tool's result could not be written: \
                                        %s"
                                       why);
                                 P.error ~id P.Code.internal_error
                                   "Internal error"
                           in
                           Eio.Stream.add call.notes (Answer text))
                         (fun () ->
                           (* Once the client has gone nothing more is sent, and
                              the reports are still taken, so a tool reporting
                              never waits on a reader that left. *)
                           let rec drain live =
                             match Eio.Stream.take call.notes with
                             | Report r ->
                                 drain (live && Result.is_ok (send (event r)))
                             | Answer a ->
                                 if live then
                                   ignore (send (event a) : (unit, _) result)
                           in
                           drain true);
                       Ok ()))))
    (* resources §Capabilities: a server that names no resources serves none
       of their methods. *)
    | ("resources/list" | "resources/templates/list" | "resources/read")
      when List.is_empty resources && Option.is_none changes ->
        fail ~status:`Not_found P.Code.method_not_found "Method not found"
    | "subscriptions/listen" -> (
        match (changes, P.member "notifications" params) with
        | None, _ ->
            fail ~status:`Not_found P.Code.method_not_found "Method not found"
        | Some hub, (Some (Value.Object _) as filter) ->
            (* What a read would answer for this caller, so a listen reveals
               nothing a read would not: the read is run once, its contents
               dropped. *)
            let readable uri =
              match
                List.find_map
                  (fun ((r : resource), read) ->
                    Option.map (fun v -> (r, read, v)) (names_it r uri))
                  reads
              with
              | Some (r, read, variables) when granted r.scope claims -> (
                  match read variables with
                  | Read _ -> true
                  | Not_found | Unreadable _ | Refused _ | Failed _ -> false)
              | Some _ | None -> false
            in
            let asked =
              match P.member "resourceSubscriptions" filter with
              | Some (Value.Array uris) ->
                  List.filter_map
                    (function Value.String u -> Some u | _ -> None)
                    uris
              | _ -> []
            in
            let honoured =
              List.fold_left
                (fun acc uri ->
                  if
                    List.length acc >= max_subscriptions
                    || List.mem uri acc
                    || not (readable uri)
                  then acc
                  else acc @ [ uri ])
                [] asked
            in
            let tagged =
              ( "_meta",
                Value.Object
                  [
                    ("io.modelcontextprotocol/subscriptionId", P.id_to_value id);
                  ] )
            in
            let event data =
              match Spindle_http.Event_stream.event data with
              | Ok e -> e
              | Error _ -> ""
            in
            (* subscriptions §Opening a Stream: the subset honoured, the types
               not served omitted. *)
            let acknowledged =
              P.notification "notifications/subscriptions/acknowledged"
                [
                  tagged;
                  ( "notifications",
                    Value.Object
                      (match honoured with
                      | [] -> []
                      | _ :: _ ->
                          [
                            ( "resourceSubscriptions",
                              Value.Array
                                (List.map (fun u -> Value.String u) honoured) );
                          ]) );
                ]
            in
            let updated uri =
              P.notification "notifications/resources/updated"
                [ ("uri", Value.String uri); tagged ]
            in
            (* subscriptions §Cancellation: a server ending a listen sends a
               successful response, never notifications/cancelled, which HTTP
               has no use for (issue #3348). *)
            let completed =
              P.result id
                [
                  complete;
                  ( "_meta",
                    Value.Object
                      [
                        ( "io.modelcontextprotocol/subscriptionId",
                          P.id_to_value id );
                        ("io.modelcontextprotocol/serverInfo", served);
                      ] );
                ]
            in
            let watch send subscriptions =
              let ends =
                Eio.Fiber.List.map
                  (fun sub ->
                    let ended =
                      Spindle.Broadcast.forward ~until:gone sub (fun uri ->
                          send (event (updated uri)))
                    in
                    List.iter (Spindle.Broadcast.unsubscribe hub) subscriptions;
                    ended)
                  subscriptions
              in
              match List.find_opt Result.is_error ends with
              | Some ended -> ended
              | None ->
                  (* Only the server ending it is graceful: a client dropped
                     as slow has missed changes, and listens again. *)
                  if
                    Eio.Promise.is_resolved gone
                    || List.exists Spindle.Broadcast.dropped subscriptions
                  then Ok ()
                  else send (event completed)
            in
            (* Subscribed to every URI before the acknowledgment is written,
               so a change made the instant after reaches it. *)
            let rec subscribed send subscriptions = function
              | uri :: rest ->
                  Spindle.Broadcast.subscribe hub ~topic:uri () (fun sub ->
                      subscribed send (sub :: subscriptions) rest)
              | [] -> (
                  let* () = send (event acknowledged) in
                  match subscriptions with
                  | [] -> send (event completed)
                  | _ :: _ -> watch send subscriptions)
            in
            Ok
              (Spindle.Response.events (fun send -> subscribed send [] honoured))
        | Some _, _ ->
            fail P.Code.invalid_params "Invalid params: no notifications")
    | "resources/list" | "resources/templates/list" -> (
        match P.member "cursor" params with
        | Some _ -> fail P.Code.invalid_params "Invalid params: no such cursor"
        | None ->
            let described (r : resource) =
              [ ("name", Value.String r.name) ]
              @ opt "title" r.title @ opt "description" r.doc
              @ opt "mimeType" r.mime
            in
            let key, listed =
              match meth with
              | "resources/list" ->
                  ( "resources",
                    fun (r : resource) ->
                      match r.uri with
                      | Fixed uri ->
                          Some
                            (Value.Object
                               (("uri", Value.String uri) :: described r))
                      | Templated _ -> None )
              | _ ->
                  ( "resourceTemplates",
                    fun (r : resource) ->
                      match r.uri with
                      | Templated t ->
                          Some
                            (Value.Object
                               (("uriTemplate", Value.String t.text)
                               :: described r))
                      | Fixed _ -> None )
            in
            ok
              ([
                 complete;
                 ( key,
                   Value.Array
                     (List.filter_map
                        (fun (r : resource) ->
                          if granted r.scope claims then listed r else None)
                        resources) );
               ]
              @ cacheable))
    | "resources/read" -> (
        match P.member "uri" params with
        | Some (Value.String uri) -> (
            (* resources §Error Handling: a resource not found is -32602,
               naming the URI. *)
            let not_found () =
              fail
                ~data:(Value.Object [ ("uri", Value.String uri) ])
                P.Code.invalid_params "Resource not found"
            in
            match
              List.find_map
                (fun ((r : resource), read) ->
                  Option.map
                    (fun variables -> (r, read, variables))
                    (names_it r uri))
                reads
            with
            | None -> not_found ()
            | Some (r, _, _) when not (granted r.scope claims) -> (
                match (auth, r.scope) with
                | Some a, Some s -> Error (Bearer.lacking a s)
                | _ -> not_found ())
            | Some (r, read, variables) -> (
                match read variables with
                | Read contents ->
                    ok
                      ([
                         complete;
                         ( "contents",
                           Value.Array
                             (List.map (content_value uri r.mime) contents) );
                       ]
                      @ cached (Option.value r.ttl_ms ~default:ttl_ms))
                | Not_found -> not_found ()
                | Unreadable problems ->
                    fail P.Code.invalid_params
                      ("Invalid params: " ^ String.concat "; " problems)
                | Refused refusal -> Error refusal
                | Failed why ->
                    fail P.Code.internal_error ("Internal error: " ^ why)))
        | _ -> fail P.Code.invalid_params "Invalid params: no uri")
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
        (List.fold_left
           (fun acc code ->
             if List.exists (Spindle.Refusal.Code.equal code) acc then acc
             else acc @ [ code ])
           (match auth with
           | Some _ -> [ Bearer.insufficient_scope ]
           | None -> [])
           (List.concat_map (fun (r : resource) -> r.codes) resources))
      path Spindle.Returns.response
      (let+ () = guard
       and+ claims = claims
       and+ version_header = header "mcp-protocol-version"
       and+ method_header = header "mcp-method"
       and+ name_header = header "mcp-name"
       and+ runs = runs
       and+ reads = reads
       and+ gone = Spindle.client_gone
       and+ call = call
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
             (fun () ->
               answer ~id ~meth ~params ~claims ~runs ~reads ~gone ~call));
  ]

module Test = struct
  (* The headers and the body a client sends for [meth]. *)
  let request ?progress_token ~headers ~capabilities meth params =
    let meta =
      Value.Object
        ((match progress_token with
           | Some token -> [ ("progressToken", Value.String token) ]
           | None -> [])
        @ [
            ("io.modelcontextprotocol/protocolVersion", Value.String P.version);
            ("io.modelcontextprotocol/clientCapabilities", capabilities);
          ])
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
    ( [
        ("content-type", "application/json");
        ("accept", "application/json, text/event-stream");
        ("mcp-protocol-version", P.version);
        ("mcp-method", meth);
      ]
      @ named @ headers,
      text )

  let call ?now ?progress_token ?(path = "/mcp") ?(headers = [])
      ?(capabilities = Value.Object []) app meth params =
    let headers, body =
      request ?progress_token ~headers ~capabilities meth params
    in
    Spindle.Test.call ?now ~headers ~body app `POST path

  let events ?now ?(path = "/mcp") ?(headers = [])
      ?(capabilities = Value.Object []) app meth params f =
    let headers, body = request ~headers ~capabilities meth params in
    Spindle.Test.events ?now ~headers ~meth:`POST ~body app path f
end
