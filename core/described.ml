module Websocket = Spindle_http.Websocket
module Code = Refusal.Code
module S = Wiretype.Schema

type returns =
  | Value of {
      statuses : (int * string option) list;
      schema : S.t;
      examples : string list;
    }
  | Html
  | Text
  | Empty of (int * string option) list
  | Response
  | Events of (string * data) list
  | Socket of { subprotocol : string option; client : data; server : data }

and data = Json_data of S.t | Text_data | Binary_data

type body =
  | Json_body of { schema : S.t; examples : string list; required : bool }
  | Form_body of { fields : S.t; files : Dep.file list }
  | Parts_body
  | Raw_body

type located = In_path | In_query | In_header | In_cookie
type default = Bare of string | Quoted of string

type parameter = {
  name : string;
  located : located;
  required : bool;
  schema : S.t;
  default : default option;
}

type route = {
  info : Route.info;
  operation_id : string;
  summary : string option;
  doc : string option;
  tags : string list;
  parameters : parameter list;
  credentials : Dep.credential list;
  anonymous : bool;
  codes : Code.t list;
  returns : returns;
  body : body option;
}

type t = {
  routes : route list;
  components : (string * S.t) list;
  codes : Code.t list;
  loose : string list;
  errors : string list;
}

let of_shape = function
  | Codec.String -> S.String S.text
  | Codec.Format f -> S.String { S.text with format = Some f }
  | Codec.Integer -> S.Integer S.no_bounds
  | Codec.Number -> S.Number S.no_bounds
  | Codec.Boolean -> S.Boolean
  | Codec.Enum words -> S.String { S.text with words = Some words }

let operation_id (i : Route.info) =
  let word =
    String.map
      (function ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9') as c -> c | _ -> '_')
      i.pattern
  in
  let parts =
    List.filter
      (fun w -> not (String.equal w ""))
      (String.split_on_char '_' word)
  in
  String.lowercase_ascii (Spindle_http.Meth.to_string i.meth)
  ^ match parts with [] -> "_root" | _ -> "_" ^ String.concat "_" parts

let route_name (i : Route.info) =
  Spindle_http.Meth.to_string i.meth ^ " " ^ i.pattern

let encode_examples description vs =
  List.filter_map (fun v -> Result.to_option (Wiretype.encode description v)) vs

let listed_statuses statuses =
  List.map (fun (s, doc) -> (Spindle_http.Status.to_int s, Some doc)) statuses

let returns_of ctx (i : Route.info) =
  let at = route_name i in
  match i.returns with
  | Returns.Json { status; description; examples = vs } ->
      Value
        {
          statuses = [ (Spindle_http.Status.to_int status, None) ];
          schema = S.walk ctx Encode ~at description;
          examples = encode_examples description vs;
        }
  | Returns.Json_response { statuses; description; examples = vs } ->
      Value
        {
          statuses = listed_statuses statuses;
          schema = S.walk ctx Encode ~at description;
          examples = encode_examples description vs;
        }
  | Returns.Html -> Html
  | Returns.Text -> Text
  | Returns.Empty status -> Empty [ (Spindle_http.Status.to_int status, None) ]
  | Returns.Empty_response statuses -> Empty (listed_statuses statuses)
  | Returns.Response -> Response
  | Returns.Events declared ->
      Events
        (List.map
           (fun (Event.Declared k) ->
             ( Event.kind_name k,
               match Event.kind_data k with
               | Event.Json description ->
                   Json_data
                     (S.walk ctx Encode
                        ~at:(at ^ " event " ^ Event.kind_name k)
                        description)
               | Event.Text -> Text_data ))
           declared)
  | Returns.Websocket protocol ->
      (* The client's messages are decoded, the server's encoded. *)
      let data : type a. S.dir -> string -> a Websocket.message -> data =
       fun direction side -> function
         | Websocket.Json d ->
             Json_data (S.walk ctx direction ~at:(at ^ " " ^ side) d)
         | Websocket.Text -> Text_data
         | Websocket.Binary -> Binary_data
      in
      Socket
        {
          subprotocol = Websocket.subprotocol protocol;
          client = data Decode "client" (Websocket.client protocol);
          server = data Encode "server" (Websocket.server protocol);
        }

(* Flat strings with repeats, as a query is. *)
let form_schema (i : Route.info) =
  S.Object
    {
      about = "A form: each field its value, a repeated one a list of them.";
      additional = Allowed;
      props =
        List.filter_map
          (function
            | Dep.Field (f : Dep.input) ->
                let one = of_shape f.shape in
                Some
                  {
                    S.name = f.name;
                    schema =
                      (if f.many then
                         S.Array
                           { items = one; min_items = None; max_items = None }
                       else one);
                    required = f.required;
                    doc = "";
                    deprecated = false;
                    examples = [];
                  }
            | Dep.Path _ | Dep.Query _ | Dep.Header _ | Dep.Cookie _
            | Dep.File _ | Dep.Body _ | Dep.Custom _ ->
                None)
          i.needs;
    }

let body_of ctx (i : Route.info) =
  List.find_map
    (function
      | Dep.Body Dep.Form ->
          Some
            (Form_body
               {
                 fields = form_schema i;
                 files =
                   List.filter_map
                     (function Dep.File f -> Some f | _ -> None)
                     i.needs;
               })
      | Dep.Body Dep.Multipart -> Some Parts_body
      | Dep.Body (Dep.Raw | Dep.Stream) -> Some Raw_body
      | Dep.Body (Dep.Json { description; examples = vs }) ->
          Some
            (Json_body
               {
                 schema =
                   S.walk ctx Decode ~at:(route_name i ^ " body") description;
                 examples = encode_examples description vs;
                 (* Spindle.json reads an empty body as {}, so the body is
                    required exactly where {} does not decode. *)
                 required = Result.is_error (Wiretype.decode description "{}");
               })
      | Dep.Path _ | Dep.Query _ | Dep.Header _ | Dep.Cookie _ | Dep.Field _
      | Dep.File _ | Dep.Custom _ ->
          None)
    i.needs

let distinct equal xs =
  List.fold_left
    (fun acc x -> if List.exists (equal x) acc then acc else acc @ [ x ])
    [] xs

let dedupe_codes codes = distinct Code.equal codes

let credential_reads (i : Route.info) =
  List.concat_map (fun (c : Dep.credential) -> c.reads) i.credentials

(* A credential is described once, as its security scheme, and never again
   among the parameters. *)
let is_credential i need =
  List.exists
    (fun read ->
      match (read, need) with
      | Dep.Cookie a, Dep.Cookie b
      | Dep.Header a, Dep.Header b
      | Dep.Query a, Dep.Query b ->
          String.equal a.name b.name
      | _ -> false)
    (credential_reads i)

let input_parameter located (i : Dep.input) =
  let one = of_shape i.shape in
  if i.many then
    {
      name = i.name;
      located;
      required = i.required;
      schema = S.Array { items = one; min_items = None; max_items = None };
      default = None;
    }
  else
    {
      name = i.name;
      located;
      required = i.required;
      schema = one;
      default =
        Option.map
          (fun text ->
            match i.shape with
            | Codec.Integer | Codec.Number | Codec.Boolean -> Bare text
            | Codec.String | Codec.Format _ | Codec.Enum _ -> Quoted text)
          i.default;
    }

let parameters_of (i : Route.info) =
  List.map
    (fun (p : Route.param) ->
      {
        name = p.name;
        located = In_path;
        required = true;
        schema = of_shape p.shape;
        default = None;
      })
    i.params
  @ List.filter_map
      (fun need ->
        if is_credential i need then None
        else
          match need with
          | Dep.Query x -> Some (input_parameter In_query x)
          | Dep.Header x -> Some (input_parameter In_header x)
          | Dep.Cookie x -> Some (input_parameter In_cookie x)
          | Dep.Path _ | Dep.Field _ | Dep.File _ | Dep.Body _ | Dep.Custom _ ->
              None)
      i.needs

(* Anonymous access is answered where the route reads no credential, or
   every credential read is optional and the route never refuses with a 401
   (RFC 9110 §15.5.2). *)
let anonymous_of (i : Route.info) =
  match i.credentials with
  | [] -> true
  | _ :: _ ->
      let is_unauthorized c =
        Spindle_http.Status.equal (Code.status c) `Unauthorized
      in
      (not (List.exists is_unauthorized i.codes))
      && List.for_all
           (function
             | Dep.Cookie x | Dep.Header x | Dep.Query x -> not x.required
             | _ -> true)
           (credential_reads i)

let route_of info returns body =
  {
    info;
    operation_id = operation_id info;
    summary = Meta.find Meta.summary info.meta;
    doc = Meta.find Meta.doc info.meta;
    tags = Option.value ~default:[] (Meta.find Meta.tags info.meta);
    parameters = parameters_of info;
    credentials = info.credentials;
    anonymous = anonymous_of info;
    codes = dedupe_codes (info.codes @ Route_repr.framework_codes info);
    returns;
    body;
  }

(* ------------------------------------------------------------------ *)
(* Routes that share a method and a pattern, as one operation *)

(* Two schemas are one where they say the same JSON Schema. *)
let same_schema a b =
  Wiretype.Value.equal (S.Json_schema.of_t a) (S.Json_schema.of_t b)

let either schemas =
  let alternatives = function S.Union ts -> ts | t -> [ t ] in
  match distinct same_schema (List.concat_map alternatives schemas) with
  | [ one ] -> one
  | several -> S.Union several

let equal_located a b =
  match (a, b) with
  | In_path, In_path
  | In_query, In_query
  | In_header, In_header
  | In_cookie, In_cookie ->
      true
  | (In_path | In_query | In_header | In_cookie), _ -> false

let equal_default a b =
  match (a, b) with
  | Some (Bare x), Some (Bare y) | Some (Quoted x), Some (Quoted y) ->
      String.equal x y
  | None, None -> true
  | (Some (Bare _ | Quoted _) | None), _ -> false

let same_input (p : parameter) (q : parameter) =
  equal_located p.located q.located && String.equal p.name q.name

let merged_parameters routes =
  let all = List.concat_map (fun r -> r.parameters) routes in
  List.map
    (fun (p : parameter) ->
      let alike = List.filter (same_input p) all in
      {
        p with
        required =
          List.for_all (fun r -> List.exists (same_input p) r.parameters) routes
          && List.for_all (fun (q : parameter) -> q.required) alike;
        schema = either (List.map (fun (q : parameter) -> q.schema) alike);
        default =
          (match
             distinct equal_default
               (List.map (fun (q : parameter) -> q.default) alike)
           with
          | [ one ] -> one
          | _ -> None);
      })
    (distinct same_input all)

let merged_statuses statuses =
  distinct (fun (a, _) (b, _) -> Int.equal a b) statuses

let merged_returns a b =
  match (a, b) with
  | Value x, Value y ->
      Some
        (Value
           {
             statuses = merged_statuses (x.statuses @ y.statuses);
             schema = either [ x.schema; y.schema ];
             examples = x.examples @ y.examples;
           })
  | Empty x, Empty y -> Some (Empty (merged_statuses (x @ y)))
  | Html, Html -> Some Html
  | Text, Text -> Some Text
  | Response, Response -> Some Response
  | (Value _ | Empty _ | Html | Text | Response | Events _ | Socket _), _ ->
      None

let same_file (f : Dep.file) (g : Dep.file) =
  String.equal f.name g.name
  && Bool.equal f.required g.required
  && Bool.equal f.many g.many

(* A route that reads no body is answered without one, so the operation's
   is not required. *)
let merged_body a b =
  match (a, b) with
  | None, None -> Some None
  | Some (Json_body x), None | None, Some (Json_body x) ->
      Some (Some (Json_body { x with required = false }))
  | Some x, None | None, Some x -> Some (Some x)
  | Some (Json_body x), Some (Json_body y) ->
      Some
        (Some
           (Json_body
              {
                schema = either [ x.schema; y.schema ];
                examples = x.examples @ y.examples;
                required = x.required && y.required;
              }))
  | Some (Form_body x), Some (Form_body y)
    when same_schema x.fields y.fields && List.equal same_file x.files y.files
    ->
      Some a
  | Some Parts_body, Some Parts_body | Some Raw_body, Some Raw_body -> Some a
  | Some (Json_body _ | Form_body _ | Parts_body | Raw_body), Some _ -> None

let joined sep texts =
  match distinct String.equal (List.filter_map Fun.id texts) with
  | [] -> None
  | some -> Some (String.concat sep some)

(* What cannot be one operation is the document's error, as two paths that
   make one id are. *)
let merged first rest =
  let routes = first :: rest in
  let name = route_name first.info in
  let fold f start xs =
    List.fold_left
      (fun acc x -> Option.bind acc (fun v -> f v x))
      (Some start) xs
  in
  match
    ( fold merged_returns first.returns (List.map (fun r -> r.returns) rest),
      fold merged_body first.body (List.map (fun r -> r.body) rest) )
  with
  | Some returns, Some body ->
      Ok
        {
          first with
          summary = joined "; " (List.map (fun r -> r.summary) routes);
          doc = joined "\n\n" (List.map (fun r -> r.doc) routes);
          tags =
            distinct String.equal (List.concat_map (fun r -> r.tags) routes);
          parameters = merged_parameters routes;
          credentials =
            distinct
              (fun (a : Dep.credential) (b : Dep.credential) ->
                String.equal a.scheme b.scheme)
              (List.concat_map (fun r -> r.credentials) routes);
          anonymous = List.exists (fun r -> r.anonymous) routes;
          codes =
            dedupe_codes (List.concat_map (fun (r : route) -> r.codes) routes);
          returns;
          body;
        }
  | returns, body ->
      Error
        ((match returns with
           | Some _ -> []
           | None ->
               [
                 name
                 ^ " is one operation to OpenAPI, and its routes answer in \
                    different ways, which one operation cannot say";
               ])
        @
        match body with
        | Some _ -> []
        | None ->
            [
              name
              ^ " is one operation to OpenAPI, and its routes read different \
                 bodies, which one operation cannot say";
            ])

(* The routes of each method and pattern, in the order the first of each
   was listed. *)
let operations routes =
  let same (a : route) (b : route) =
    Spindle_http.Meth.equal a.info.meth b.info.meth
    && String.equal a.info.pattern b.info.pattern
  in
  List.fold_left
    (fun groups r ->
      if List.exists (fun (first, _) -> same first r) groups then
        List.map
          (fun (first, rest) ->
            if same first r then (first, rest @ [ r ]) else (first, rest))
          groups
      else groups @ [ (r, []) ])
    [] routes

(* A pattern with its parameters' names left out: two that are equal are
   one path to OpenAPI. *)
let unnamed pattern =
  let b = Buffer.create (String.length pattern) in
  let (_ : bool) =
    String.fold_left
      (fun inside c ->
        match (c, inside) with
        | '{', _ ->
            Buffer.add_string b "{}";
            true
        | '}', _ -> false
        | _, true -> true
        | _, false ->
            Buffer.add_char b c;
            false)
      false pattern
  in
  Buffer.contents b

let rec name_clashes = function
  | [] -> []
  | (r : Route.info) :: rest ->
      List.filter_map
        (fun (r' : Route.info) ->
          if
            String.equal (unnamed r.pattern) (unnamed r'.pattern)
            && not (String.equal r.pattern r'.pattern)
          then
            Some
              (Printf.sprintf
                 "%s and %s are one path to OpenAPI, which names a parameter \
                  once: give them one name"
                 (route_name r) (route_name r'))
          else None)
        rest
      @ name_clashes rest

(* Two paths can make one id, [/a-b] and [/a_b], which a generated client
   would give one name. *)
let rec operation_id_clashes = function
  | [] -> []
  | r :: rest ->
      List.filter_map
        (fun r' ->
          if String.equal r.operation_id r'.operation_id then
            Some
              (Printf.sprintf "%s and %s are both the operation %s"
                 (route_name r.info) (route_name r'.info) r.operation_id)
          else None)
        rest
      @ operation_id_clashes rest

let of_app app =
  (* OpenAPI forbids "/" in a path parameter, so a route with a rest cannot
     be described; it serves files, not an API. *)
  let infos =
    List.filter
      (fun (i : Route.info) ->
        not (List.exists (fun (p : Route.param) -> p.rest) i.params))
      (App.routes app)
  in
  let ctx = S.create () in
  (* The refusal first, which every route may answer, from the description
     it is written with. *)
  ignore (S.walk ctx S.Encode ~at:"a refusal" Response.refusal_json : S.t);
  (* Answers before bodies: a component both share is the answer's, and the
     body's is named apart only if it differs. *)
  let answers = List.map (returns_of ctx) infos in
  let bodies = List.map (body_of ctx) infos in
  let each =
    List.map2
      (fun (info, returns) body -> route_of info returns body)
      (List.combine infos answers)
      bodies
  in
  let operations =
    List.map (fun (r, rest) -> merged r rest) (operations each)
  in
  let routes = List.filter_map Result.to_option operations in
  let opaque =
    List.filter_map
      (fun (i : Route.info) ->
        if i.opaque then
          Some
            (route_name i
           ^ ": reads more than it says (a bind, or a dependency with no \
              ~needs)")
        else None)
      infos
  in
  {
    routes;
    components = S.components ctx;
    codes =
      dedupe_codes
        (List.concat_map
           (fun (i : Route.info) -> i.codes @ Route_repr.framework_codes i)
           infos);
    loose = List.sort_uniq String.compare (opaque @ S.loose ctx);
    errors =
      List.map S.error_to_string (S.errors ctx)
      @ name_clashes infos
      @ List.concat_map
          (function Ok _ -> [] | Error problems -> problems)
          operations
      @ operation_id_clashes routes;
  }
