module Code = Refusal.Code
module D = Described
module S = Wiretype.Schema

(* Out's, restated so its constructors read bare without an open. *)
type json = Out.t =
  | Null
  | Bool of bool
  | Int of int
  | String of string
  | List of json list
  | Obj of (string * json) list
  | Raw of string

let schema_ref name = Obj [ ("$ref", String ("#/components/schemas/" ^ name)) ]

(* Components live under OpenAPI's [#/components/schemas], not [$defs]. *)
let schema s = Out.of_value (S.Json_schema.of_t ~defs:"#/components/schemas/" s)
let json_content s = Obj [ ("application/json", Obj [ ("schema", s) ]) ]

let parameter_object where (i : Dep.input) =
  Obj
    [
      ("name", String i.name);
      ("in", String where);
      ("required", Bool i.required);
      ( "schema",
        let s = schema (D.of_shape i.shape) in
        if i.many then Obj [ ("type", String "array"); ("items", s) ] else s );
    ]

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

let parameters (r : D.route) =
  List.map
    (fun (p : Route.param) ->
      Obj
        [
          ("name", String p.name);
          ("in", String "path");
          ("required", Bool true);
          ("schema", schema (D.of_shape p.shape));
        ])
    r.info.params
  @ List.filter_map
      (fun need ->
        if is_credential r.info need then None
        else
          match need with
          | Dep.Query i -> Some (parameter_object "query" i)
          | Dep.Header i -> Some (parameter_object "header" i)
          | Dep.Cookie i -> Some (parameter_object "cookie" i)
          | Dep.Path _ | Dep.Field _ | Dep.File _ | Dep.Body _ | Dep.Custom _ ->
              None)
      r.info.needs

let examples = function
  | [] -> []
  | xs ->
      [
        ( "examples",
          Obj
            (List.mapi
               (fun n x -> (string_of_int n, Obj [ ("value", Raw x) ]))
               xs) );
      ]

let responses (r : D.route) =
  let text_response status media =
    [
      ( string_of_int status,
        Obj
          [
            ("description", String "The answer.");
            ( "content",
              Obj
                [
                  (media, Obj [ ("schema", Obj [ ("type", String "string") ]) ]);
                ] );
          ] );
    ]
  in
  let success =
    match r.returns with
    | D.Value { statuses; schema = s; examples = xs } ->
        List.map
          (fun (status, doc) ->
            ( string_of_int status,
              Obj
                [
                  ( "description",
                    String (Option.value doc ~default:"The answer.") );
                  ( "content",
                    Obj
                      [
                        ( "application/json",
                          Obj ([ ("schema", schema s) ] @ examples xs) );
                      ] );
                ] ))
          statuses
    | D.Html -> text_response 200 "text/html"
    | D.Text -> text_response 200 "text/plain"
    | D.Empty statuses ->
        List.map
          (fun (status, doc) ->
            ( string_of_int status,
              Obj
                [
                  ( "description",
                    String (Option.value doc ~default:"No content.") );
                ] ))
          statuses
    | D.Response ->
        [
          ( "default",
            Obj
              [
                ( "description",
                  String
                    "A response of the route's own: a page, a redirect, a \
                     file, or nothing." );
              ] );
        ]
    | D.Socket { subprotocol; client; server } ->
        (* OpenAPI has no field for what a socket carries, so [x-websocket]
           holds the schemas. *)
        let message_schema = function
          | D.Json_data s -> schema s
          | D.Text_data -> Obj [ ("type", String "string") ]
          | D.Binary_data ->
              Obj
                [
                  ("type", String "string");
                  ("contentMediaType", String "application/octet-stream");
                ]
        in
        [
          ( "101",
            Obj
              [
                ( "description",
                  String
                    ("A WebSocket"
                    ^ (match subprotocol with
                      | Some n -> ", speaking " ^ n
                      | None -> "")
                    ^ ". What each side sends is x-websocket's client and \
                       server.") );
                ( "x-websocket",
                  Obj
                    ((match subprotocol with
                       | Some n -> [ ("subprotocol", String n) ]
                       | None -> [])
                    @ [
                        ("client", message_schema client);
                        ("server", message_schema server);
                      ]) );
              ] );
        ]
    | D.Events events ->
        (* Each item is an event as a browser parses it; a comment or a lone
           [retry:] is none. *)
        let event (name, data) =
          let data =
            match data with
            | D.Json_data s ->
                [
                  ( "data",
                    Obj
                      [
                        ("contentMediaType", String "application/json");
                        ("contentSchema", schema s);
                      ] );
                ]
            | D.Text_data | D.Binary_data -> []
          in
          Obj
            [
              ( "properties",
                Obj (("event", Obj [ ("const", String name) ]) :: data) );
            ]
        in
        let string = Obj [ ("type", String "string") ] in
        [
          ( "200",
            Obj
              [
                ( "description",
                  String
                    ("Server-Sent Events: "
                    ^ String.concat ", " (List.map fst events)
                    ^ ".") );
                ( "content",
                  Obj
                    [
                      ( "text/event-stream",
                        Obj
                          [
                            ( "itemSchema",
                              Obj
                                [
                                  ("type", String "object");
                                  ( "required",
                                    List [ String "event"; String "data" ] );
                                  ( "properties",
                                    Obj
                                      [
                                        ("event", string);
                                        ("data", string);
                                        ("id", string);
                                        ( "retry",
                                          Obj
                                            [
                                              ("type", String "integer");
                                              ("minimum", Int 0);
                                            ] );
                                      ] );
                                  ("oneOf", List (List.map event events));
                                ] );
                          ] );
                    ] );
              ] );
        ]
  in
  let codes = r.info.codes @ D.framework_codes r.info in
  let statuses =
    List.sort_uniq Int.compare
      (List.map (fun c -> Spindle_http.Status.to_int (Code.status c)) codes)
  in
  let refused =
    List.map
      (fun status ->
        let codes_with_status =
          List.fold_left
            (fun acc c ->
              if
                Spindle_http.Status.to_int (Code.status c) = status
                && not (List.exists (Code.equal c) acc)
              then acc @ [ c ]
              else acc)
            [] codes
        in
        ( string_of_int status,
          Obj
            [
              ( "description",
                String
                  (String.concat " "
                     (List.map
                        (fun c -> Code.name c ^ ": " ^ Code.doc c)
                        codes_with_status)) );
              ("content", json_content (schema_ref "Refusal"));
            ] ))
      statuses
  in
  Obj (success @ refused)

(* Anonymous access is listed where every credential read is optional and
   the route never refuses with a 401 (RFC 9110 §15.5.2). *)
let security (r : D.route) =
  match r.info.credentials with
  | [] -> []
  | creds ->
      let is_unauthorized c =
        Spindle_http.Status.equal (Code.status c) `Unauthorized
      in
      let allows_anonymous =
        (not (List.exists is_unauthorized r.info.codes))
        && List.for_all
             (function
               | Dep.Cookie i | Dep.Header i | Dep.Query i -> not i.required
               | _ -> true)
             (credential_reads r.info)
      in
      [
        ( "security",
          List
            (List.map
               (fun (c : Dep.credential) -> Obj [ (c.scheme, List []) ])
               creds
            @ if allows_anonymous then [ Obj [] ] else []) );
      ]

let request_body (r : D.route) =
  match r.body with
  | Some (D.Json_body { schema = s; examples = xs }) ->
      [
        ( "requestBody",
          Obj
            [
              ( "content",
                Obj
                  [
                    ( "application/json",
                      Obj ([ ("schema", schema s) ] @ examples xs) );
                  ] );
            ] );
      ]
  | Some (D.Form_body { fields; files }) ->
      let with_files =
        match (fields, files) with
        | _, [] -> fields
        | Wiretype.Schema.Object o, _ :: _ ->
            Wiretype.Schema.Object
              {
                o with
                props =
                  o.props
                  @ List.map
                      (fun (f : Dep.file) ->
                        let one = Wiretype.Schema.String Wiretype.Schema.text in
                        {
                          Wiretype.Schema.name = f.name;
                          schema =
                            (if f.many then
                               Wiretype.Schema.Array
                                 {
                                   items = one;
                                   min_items = None;
                                   max_items = None;
                                 }
                             else one);
                          required = f.required;
                          doc = "A file.";
                          deprecated = false;
                          examples = [];
                        })
                      files;
              }
        | _, _ :: _ -> fields
      in
      let multipart =
        ( "multipart/form-data",
          Obj
            ([ ("schema", schema with_files) ]
            @
            match files with
            | [] -> []
            | _ :: _ ->
                [
                  ( "encoding",
                    Obj
                      (List.map
                         (fun (f : Dep.file) ->
                           ( f.name,
                             Obj
                               [
                                 ( "contentType",
                                   String "application/octet-stream" );
                               ] ))
                         files) );
                ]) )
      in
      [
        ( "requestBody",
          Obj
            [
              ( "content",
                Obj
                  (match files with
                  | [] ->
                      [
                        ( "application/x-www-form-urlencoded",
                          Obj [ ("schema", schema fields) ] );
                        multipart;
                      ]
                  | _ :: _ -> [ multipart ]) );
            ] );
      ]
  | Some D.Parts_body ->
      [
        ( "requestBody",
          Obj
            [
              ( "content",
                Obj
                  [
                    ( "multipart/form-data",
                      Obj [ ("schema", Obj [ ("type", String "object") ]) ] );
                  ] );
            ] );
      ]
  | Some D.Raw_body ->
      [
        ( "requestBody",
          Obj
            [
              ( "content",
                Obj
                  [
                    ( "application/octet-stream",
                      Obj [ ("schema", Obj [ ("type", String "string") ]) ] );
                  ] );
            ] );
      ]
  | None -> []

let operation (r : D.route) =
  let meta = r.info.meta in
  let from_meta k f =
    match Meta.find k meta with Some v -> [ f v ] | None -> []
  in
  Obj
    ([ ("operationId", String r.operation_id) ]
    @ from_meta Meta.summary (fun s -> ("summary", String s))
    @ from_meta Meta.doc (fun s -> ("description", String s))
    @ from_meta Meta.tags (fun t ->
        ("tags", List (List.map (fun s -> String s) t)))
    @ (match parameters r with [] -> [] | ps -> [ ("parameters", List ps) ])
    @ request_body r
    @ [ ("responses", responses r) ]
    @ security r)

let schemes (d : D.t) =
  List.fold_left
    (fun acc (r : D.route) ->
      List.fold_left
        (fun acc (c : Dep.credential) ->
          if List.mem_assoc c.scheme acc then acc
          else
            let where, name =
              match
                List.find_map
                  (function
                    | Dep.Cookie i -> Some ("cookie", i.name)
                    | Dep.Header i -> Some ("header", i.name)
                    | Dep.Query i -> Some ("query", i.name)
                    | _ -> None)
                  c.reads
              with
              | Some w -> w
              | None -> ("cookie", c.scheme)
            in
            (* Authorization is HTTP authentication: bearer, basic. *)
            let scheme_fields =
              if
                String.equal where "header"
                && String.equal (String.lowercase_ascii name) "authorization"
              then [ ("type", String "http"); ("scheme", String c.scheme) ]
              else
                [
                  ("type", String "apiKey");
                  ("in", String where);
                  ("name", String name);
                ]
            in
            acc
            @ [
                ( c.scheme,
                  Obj
                    (scheme_fields
                    @
                    match c.doc with
                    | Some d -> [ ("description", String d) ]
                    | None -> []) );
              ])
        acc r.info.credentials)
    [] d.routes

let paths (d : D.t) =
  List.fold_left
    (fun acc (r : D.route) ->
      let meth =
        String.lowercase_ascii (Spindle_http.Meth.to_string r.info.meth)
      in
      match List.assoc_opt r.info.pattern acc with
      | Some ops ->
          List.map
            (fun (p, o) ->
              if String.equal p r.info.pattern then
                (p, ops @ [ (meth, operation r) ])
              else (p, o))
            acc
      | None -> acc @ [ (r.info.pattern, [ (meth, operation r) ]) ])
    [] d.routes

let document ?(title = "API") ?(version = "0") app =
  let d = D.of_app app in
  match d.errors with
  | _ :: _ -> Error d.errors
  | [] ->
      Ok
        (Out.to_string
           (Obj
              [
                ("openapi", String "3.2.0");
                ( "info",
                  Obj [ ("title", String title); ("version", String version) ]
                );
                ( "paths",
                  Obj (List.map (fun (p, ops) -> (p, Obj ops)) (paths d)) );
                ( "components",
                  Obj
                    ([
                       ( "schemas",
                         Obj
                           (List.map (fun (n, s) -> (n, schema s)) d.components)
                       );
                     ]
                    @
                    match schemes d with
                    | [] -> []
                    | ss -> [ ("securitySchemes", Obj ss) ]) );
              ]))

let report app = (D.of_app app).loose

(* Everything from this server, so the page works offline and under a policy
   that allows no other host; its own script is a file rather than inline
   for the same reason. *)
let page ~title ~document ~scalar ~start =
  Printf.sprintf
    {|<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
</head>
<body>
<div id="app" data-url="%s"></div>
<script src="%s"></script>
<script src="%s"></script>
</body>
</html>
|}
    title document scalar start

let start =
  {|Scalar.createApiReference("#app", { url: document.getElementById("app").dataset.url });
|}

(* The document describes the routes it is given, not these. *)
let routes ?(at = Path.s "docs") ?document:(document_at = Path.s "openapi.json")
    ?(title = "API") ?version routes =
  let ( let* ) = Result.bind in
  let url p = Result.map_error (fun m -> [ m ]) (Path.url p []) in
  let scalar_at = Path.(at / s "scalar.js")
  and start_at = Path.(at / s "start.js") in
  let* app = Result.map_error (fun m -> [ m ]) (App.make routes) in
  let* doc = document ~title ?version app in
  let* document_url = url document_at in
  let* scalar_url = url scalar_at in
  let* start_url = url start_at in
  let served_file ctype body =
    Dep.return
      (Ok
         (Response.make ~content_type:ctype
            ~headers:[ ("cache-control", "no-cache") ]
            body))
  in
  Ok
    [
      Route_repr.get ~summary:"This API, as an OpenAPI 3.2 document" document_at
        Returns.response
        (served_file "application/json" doc);
      Route_repr.get ~summary:"This API's reference, to read and to try" at
        Returns.response
        (served_file "text/html; charset=utf-8"
           (page ~title ~document:document_url ~scalar:scalar_url
              ~start:start_url));
      Route_repr.get ~summary:"The reference's script" scalar_at
        Returns.response
        (served_file "text/javascript; charset=utf-8" Scalar.js);
      Route_repr.get ~summary:"What starts the reference" start_at
        Returns.response
        (served_file "text/javascript; charset=utf-8" start);
    ]

(* What [routes] refuses is a constant in source, so it raises, as
   [Spindle.serve] does: the program ends before it listens, saying why. *)
let docs ?at ?document ?title ?version described =
  match routes ?at ?document ?title ?version described with
  | Ok docs -> docs
  | Error problems ->
      invalid_arg ("Spindle.Openapi.docs: " ^ String.concat "; " problems)
