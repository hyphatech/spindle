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

let with_default (p : D.parameter) s =
  match (p.default, s) with
  | Some (D.Bare text), Obj members -> Obj (members @ [ ("default", Raw text) ])
  | Some (D.Quoted text), Obj members ->
      Obj (members @ [ ("default", String text) ])
  | Some _, _ | None, _ -> s

let located = function
  | D.In_path -> "path"
  | D.In_query -> "query"
  | D.In_header -> "header"
  | D.In_cookie -> "cookie"

let parameters (r : D.route) =
  List.map
    (fun (p : D.parameter) ->
      Obj
        [
          ("name", String p.name);
          ("in", String (located p.located));
          ("required", Bool p.required);
          ("schema", with_default p (schema p.schema));
        ])
    r.parameters

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
  let codes = r.codes in
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

let security (r : D.route) =
  match r.credentials with
  | [] -> []
  | creds ->
      [
        ( "security",
          List
            (List.map
               (fun (c : Dep.credential) -> Obj [ (c.scheme, List []) ])
               creds
            @ if r.anonymous then [ Obj [] ] else []) );
      ]

let request_body (r : D.route) =
  match r.body with
  | Some (D.Json_body { schema = s; examples = xs; required }) ->
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
              ("required", Bool required);
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
                        let one =
                          Wiretype.Schema.String Wiretype.Schema.Text.any
                        in
                        {
                          Wiretype.Schema.name = f.name;
                          field = None;
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
  | Some (D.Raw_body content_types) ->
      let content_types =
        match content_types with
        | [] -> [ "application/octet-stream" ]
        | named -> named
      in
      [
        ( "requestBody",
          Obj
            [
              ( "content",
                Obj
                  (List.map
                     (fun t ->
                       (t, Obj [ ("schema", Obj [ ("type", String "string") ]) ]))
                     content_types) );
            ] );
      ]
  | None -> []

let operation (r : D.route) =
  let present k f = function Some v -> [ (k, f v) ] | None -> [] in
  Obj
    ([ ("operationId", String r.operation_id) ]
    @ present "summary" (fun s -> String s) r.summary
    @ present "description" (fun s -> String s) r.doc
    @ (match r.tags with
      | [] -> []
      | tags -> [ ("tags", List (List.map (fun s -> String s) tags)) ])
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
        acc r.credentials)
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
