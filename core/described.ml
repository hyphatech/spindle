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
  | Json_body of { schema : S.t; examples : string list }
  | Form_body of { fields : S.t; files : Dep.file list }
  | Parts_body
  | Raw_body

type route = {
  info : Route.info;
  operation_id : string;
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
               })
      | Dep.Path _ | Dep.Query _ | Dep.Header _ | Dep.Cookie _ | Dep.Field _
      | Dep.File _ | Dep.Custom _ ->
          None)
    i.needs

let reads_inputs (i : Route.info) =
  (match i.params with [] -> false | _ :: _ -> true)
  || List.exists
       (function
         | Dep.Query _ | Dep.Header _ | Dep.Cookie _ | Dep.Field _ | Dep.File _
         | Dep.Body _ ->
             true
         | Dep.Path _ | Dep.Custom _ -> false)
       i.needs

let framework_codes (i : Route.info) =
  let reads_body =
    List.exists (function Dep.Body _ -> true | _ -> false) i.needs
  in
  let is_unsafe =
    match i.meth with `GET | `HEAD | `OPTIONS -> false | _ -> true
  in
  let is_websocket =
    match i.returns with
    | Returns.Websocket _ -> true
    | Returns.Json _ | Json_response _ | Html | Text | Empty _
    | Empty_response _ | Response | Events _ ->
        false
  in
  List.concat
    [
      (if reads_inputs i || is_websocket then [ Code.invalid ] else []);
      (if is_websocket then [ Code.upgrade_required ] else []);
      (if reads_body then [ Code.unreadable; Code.too_large ] else []);
      (if is_unsafe || is_websocket then [ Code.cross_origin ] else []);
      [ Code.busy; Code.internal ];
    ]

let dedupe_codes codes =
  List.fold_left
    (fun acc c -> if List.exists (Code.equal c) acc then acc else acc @ [ c ])
    [] codes

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
  let routes =
    List.map2
      (fun (info, returns) body ->
        { info; operation_id = operation_id info; returns; body })
      (List.combine infos answers)
      bodies
  in
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
           (fun (i : Route.info) -> i.codes @ framework_codes i)
           infos);
    loose = List.sort_uniq String.compare (opaque @ S.loose ctx);
    errors =
      List.map S.error_to_string (S.errors ctx) @ operation_id_clashes routes;
  }
