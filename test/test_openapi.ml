(* The generator: an application's routes as an OpenAPI document and a zod
   module, from one walk over their descriptions. How a description
   becomes a schema is wiretype's own suite's.

   What is pinned is what an application relies on without reading the
   generator: that everything a route says is in the document, that a loose
   description is reported rather than guessed at, and that /docs is served
   from here. *)

open Spindle.Syntax

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || go (i + 1))
  in
  go 0

let made routes =
  match Spindle.App.make routes with Ok a -> a | Error m -> Alcotest.fail m

let json_of_doc a =
  match Spindle.Openapi.document ~title:"Orders" ~version:"1" a with
  | Ok text -> Yojson.Safe.from_string text
  | Error e -> Alcotest.failf "no document: %s" (String.concat "; " e)

let member path j =
  List.fold_left (fun j k -> Yojson.Safe.Util.member k j) j path

let str path j = Yojson.Safe.Util.to_string (member path j)

(* ------------------------------------------------------------------ *)
(* A small application, described *)

type size = Small | Large

let size =
  Wiretype.enum ~kind:"size"
    (function Small -> "small" | Large -> "large")
    [ Small; Large ]

type item = { name : string; size : size; note : string option }

let item_json =
  Wiretype.Object.map ~kind:"item" (fun name size note -> { name; size; note })
  |> Wiretype.Object.mem "name" Wiretype.string ~doc:"What it is called."
       ~enc:(fun i -> i.name)
  |> Wiretype.Object.mem "size" size ~enc:(fun i -> i.size)
  |> Wiretype.Object.mem "note" (Wiretype.nullable Wiretype.string) ~absent:None
       ~enc:(fun i -> i.note)
  |> Wiretype.Object.finish

let gone =
  Spindle.Refusal.Code.make "gone" ~status:`Gone ~doc:"The order is closed."

let session =
  Spindle.Dep.credential ~scheme:"session" ~doc:"Who is signed in."
    (Spindle.Cookie.optional
       (Spindle.Cookie.named "session" Spindle.Codec.string))

let order_id = Spindle.Path.int "order_id"

let add =
  Spindle.post ~summary:"Add an item" ~tags:[ "orders" ] ~refuses:[ gone ]
    Spindle.Path.(s "orders" / order_id / s "items")
    (Spindle.Returns.json ~status:`Created
       ~examples:[ { name = "pen"; size = Small; note = None } ]
       item_json)
    (let+ _ = Spindle.param order_id
     and+ _ = session
     and+ _ = Spindle.Query.optional "page" Spindle.Codec.int
     and+ _ = Spindle.Query.optional "weight" Spindle.Codec.float
     and+ _ = Spindle.Query.default "limit" Spindle.Codec.int 20
     and+ _ = Spindle.Query.optional "since" Spindle.Codec.date
     and+ _ = Spindle.Query.optional "after" Spindle.Codec.instant
     and+ _ = Spindle.Header.optional "x-request" Spindle.Codec.uuid
     and+ i = Spindle.json item_json in
     Ok i)

let described = made [ add ]

let test_a_route_is_in_the_document () =
  let j = json_of_doc described in
  Alcotest.(check string) "the version" "3.2.0" (str [ "openapi" ] j);
  let op = member [ "paths"; "/orders/{order_id}/items"; "post" ] j in
  Alcotest.(check string) "its summary" "Add an item" (str [ "summary" ] op);
  Alcotest.(check string)
    "its operation" "post_orders_order_id_items" (str [ "operationId" ] op);
  let params = Yojson.Safe.Util.to_list (member [ "parameters" ] op) in
  Alcotest.(check (list string))
    "the path's parameter and the query's, not the credential"
    [
      "order_id:path:integer";
      "page:query:integer";
      "weight:query:number";
      "limit:query:integer";
      "since:query:string";
      "after:query:string";
      "x-request:header:string";
    ]
    (List.map
       (fun p ->
         str [ "name" ] p ^ ":" ^ str [ "in" ] p ^ ":"
         ^ str [ "schema"; "type" ] p)
       params);
  let param name =
    List.find_opt (fun p -> String.equal (str [ "name" ] p) name) params
    |> Option.value ~default:`Null
  in
  Alcotest.(check (list string))
    "a format where the text has one"
    [ "date"; "date-time"; "uuid" ]
    (List.map
       (fun n -> str [ "schema"; "format" ] (param n))
       [ "since"; "after"; "x-request" ]);
  Alcotest.(check string)
    "a default as its own JSON" "20"
    (Yojson.Safe.to_string (member [ "schema"; "default" ] (param "limit")));
  Alcotest.(check string)
    "and not required" "false"
    (Yojson.Safe.to_string (member [ "required" ] (param "limit")));
  Alcotest.(check string)
    "the body, a component" "#/components/schemas/Item"
    (str [ "requestBody"; "content"; "application/json"; "schema"; "$ref" ] op);
  Alcotest.(check string)
    "the answer, with its status" "#/components/schemas/Item"
    (str
       [ "responses"; "201"; "content"; "application/json"; "schema"; "$ref" ]
       op);
  Alcotest.(check bool)
    "its example" true
    (contains ~sub:{|"pen"|}
       (Yojson.Safe.to_string
          (member
             [ "responses"; "201"; "content"; "application/json"; "examples" ]
             op)));
  Alcotest.(check bool)
    "its own code, with what it means" true
    (contains ~sub:"gone: The order is closed."
       (str [ "responses"; "410"; "description" ] op));
  Alcotest.(check bool)
    "and the framework's for what it reads" true
    (contains ~sub:"invalid" (str [ "responses"; "400"; "description" ] op));
  Alcotest.(check string)
    "the credential, as a scheme" "cookie"
    (str [ "components"; "securitySchemes"; "session"; "in" ] j);
  let item = member [ "components"; "schemas"; "Item" ] j in
  Alcotest.(check (list string))
    "an enum's words, recorded" [ "small"; "large" ]
    (List.map Yojson.Safe.Util.to_string
       (Yojson.Safe.Util.to_list (member [ "properties"; "size"; "enum" ] item)));
  Alcotest.(check (list string))
    "what may be absent is not required" [ "name"; "size" ]
    (List.map Yojson.Safe.Util.to_string
       (Yojson.Safe.Util.to_list (member [ "required" ] item)));
  Alcotest.(check string)
    "a member's documentation" "What it is called."
    (str [ "properties"; "name"; "description" ] item)

(* A credential is said once, as its scheme, wherever it is read -- a query
   string's as a cookie's -- and an input of the same name somewhere else is
   still a parameter. *)
let test_a_credential_is_said_once () =
  let keyed =
    Spindle.get
      Spindle.Path.(s "keyed")
      Spindle.Returns.response
      (let+ _ =
         Spindle.Dep.credential ~scheme:"key"
           (Spindle.Query.optional "key" Spindle.Codec.string)
       and+ _ = Spindle.Header.optional "key" Spindle.Codec.string in
       Ok (Spindle.Response.empty ()))
  in
  let j = json_of_doc (made [ keyed ]) in
  let op = member [ "paths"; "/keyed"; "get" ] j in
  Alcotest.(check (list string))
    "the header alone is a parameter" [ "key:header" ]
    (List.map
       (fun p -> str [ "name" ] p ^ ":" ^ str [ "in" ] p)
       (Yojson.Safe.Util.to_list (member [ "parameters" ] op)));
  Alcotest.(check string)
    "the query's is its scheme" "query"
    (str [ "components"; "securitySchemes"; "key"; "in" ] j)

(* A credential read from Authorization is HTTP authentication under its
   scheme's name; a route that may refuse with a 401 needs its credential,
   and one that may not also takes a caller without it. *)
let test_a_credential_says_whether_it_is_needed () =
  let signed_out =
    Spindle.Refusal.Code.make "signed_out" ~status:`Unauthorized
      ~challenge:{|Bearer realm="x"|} ~doc:"No token."
  in
  let bearer =
    Spindle.Dep.credential ~scheme:"bearer"
      (Spindle.Dep.join ~refuses:[ signed_out ]
         (let+ h =
            Spindle.Header.optional "authorization" Spindle.Codec.string
          in
          Option.to_result ~none:(Spindle.Refusal.make signed_out "Sign in.") h))
  in
  let needs =
    Spindle.get
      Spindle.Path.(s "needs")
      Spindle.Returns.response
      (let+ _ = bearer in
       Ok (Spindle.Response.empty ()))
  in
  let welcomes =
    Spindle.get
      Spindle.Path.(s "welcomes")
      Spindle.Returns.response
      (let+ _ = session in
       Ok (Spindle.Response.empty ()))
  in
  let j = json_of_doc (made [ needs; welcomes ]) in
  let schemes = member [ "components"; "securitySchemes" ] j in
  Alcotest.(check string)
    "bearer is HTTP" "http"
    (str [ "bearer"; "type" ] schemes);
  Alcotest.(check string)
    "under its scheme" "bearer"
    (str [ "bearer"; "scheme" ] schemes);
  Alcotest.(check string)
    "a cookie is a key" "apiKey"
    (str [ "session"; "type" ] schemes);
  let security path =
    List.length
      (Yojson.Safe.Util.to_list (member [ "paths"; path; "get"; "security" ] j))
  in
  Alcotest.(check int) "a 401 needs the token" 1 (security "/needs");
  Alcotest.(check int)
    "an optional session also takes nobody" 2 (security "/welcomes")

(* A description the generator cannot say exactly is reported where it is,
   never guessed at; the document is still made. *)
let test_what_is_loose_is_reported () =
  let colour =
    Wiretype.enum ~kind:"colour"
      (fun n -> if n = 1 then "red" else "blue")
      [ 1; 2 ]
  in
  let loose =
    Wiretype.Object.map ~kind:"loose" (fun c j -> (c, j))
    |> Wiretype.Object.mem "colour" colour ~enc:fst
    |> Wiretype.Object.mem "anything" Wiretype.Value.json ~enc:snd
    |> Wiretype.Object.finish
  in
  let a =
    made
      [
        Spindle.get
          Spindle.Path.(s "loose")
          (Spindle.Returns.json loose)
          (Spindle.Dep.return (Ok (1, Wiretype.Value.Null)));
        Spindle.get
          Spindle.Path.(s "opaque")
          Spindle.Returns.response
          (Spindle.Dep.map
             (fun _ -> Ok (Spindle.Response.make ""))
             Spindle.request);
      ]
  in
  let report = Spindle.Openapi.report a in
  List.iter
    (fun sub ->
      Alcotest.(check bool) sub true (List.exists (contains ~sub) report))
    [ "GET /loose.anything: any JSON"; "GET /opaque: reads more than it says" ];
  (* An enum says its words wherever it was made, so it is never loose. *)
  Alcotest.(check int) "each once, and no enum" 2 (List.length report);
  Alcotest.(check (list string))
    "and a document that says everything reports nothing" []
    (Spindle.Openapi.report described)

(* OpenAPI 3.2 §4.8.12.1: an operation's parameters are unique by name and
   location, a header's name compared without case. Two reads of one input
   are one parameter, required where either is; two that read it as
   different things are refused, since no document could say both. *)
let test_two_reads_of_one_input_are_one_parameter () =
  let pages =
    Spindle.get
      Spindle.Path.(s "pages")
      Spindle.Returns.text
      (let+ _ = Spindle.Query.optional "page" Spindle.Codec.int
       and+ _ = Spindle.Query.required "page" Spindle.Codec.int
       and+ _ = Spindle.Header.optional "X-Trace" Spindle.Codec.string
       and+ _ = Spindle.Header.optional "x-trace" Spindle.Codec.string in
       Ok "")
  in
  let params =
    Yojson.Safe.Util.to_list
      (member
         [ "paths"; "/pages"; "get"; "parameters" ]
         (json_of_doc (made [ pages ])))
  in
  Alcotest.(check (list string))
    "each input once"
    [ "page:query:true"; "X-Trace:header:false" ]
    (List.map
       (fun p ->
         str [ "name" ] p ^ ":" ^ str [ "in" ] p ^ ":"
         ^ Yojson.Safe.to_string (member [ "required" ] p))
       params);
  let refused what ~says route =
    match Spindle.App.make [ route ] with
    | Ok _ -> Alcotest.failf "%s: the app was made" what
    | Error m ->
        Alcotest.(check bool) (what ^ ": " ^ m) true (contains ~sub:says m)
  in
  refused "a query read as two things" ~says:"page"
    (Spindle.get
       Spindle.Path.(s "q")
       Spindle.Returns.text
       (let+ _ = Spindle.Query.optional "page" Spindle.Codec.int
        and+ _ = Spindle.Query.optional "page" Spindle.Codec.string in
        Ok ""));
  refused "a header read as two things" ~says:"x-size"
    (Spindle.get
       Spindle.Path.(s "h")
       Spindle.Returns.text
       (let+ _ = Spindle.Header.optional "X-Size" Spindle.Codec.int
        and+ _ = Spindle.Header.optional "x-size" Spindle.Codec.bool in
        Ok ""));
  refused "a form's field read as two things" ~says:"count"
    (Spindle.post
       Spindle.Path.(s "f")
       Spindle.Returns.text
       (let+ _ = Spindle.Form.optional "count" Spindle.Codec.int
        and+ _ = Spindle.Form.list "count" Spindle.Codec.int in
        Ok ""))

(* OpenAPI 3.2 §4.8.13.1: a request body is optional unless it says
   [required]. What the document says is held to what the server answers
   an empty body, so the two cannot drift: a JSON body is read as [{}],
   refused unless every member may be left out, and a raw one is read as
   it arrived, empty or not. *)
let test_a_body_is_required_where_an_empty_one_is_refused () =
  let note =
    Wiretype.Object.map (fun note -> note)
    |> Wiretype.Object.mem "note" Wiretype.string ~absent:"" ~enc:Fun.id
    |> Wiretype.Object.finish
  in
  let post path dep =
    Spindle.post
      Spindle.Path.(s path)
      Spindle.Returns.text
      (let+ _ = dep in
       Ok "")
  in
  let stream =
    Spindle.post
      Spindle.Path.(s "stream")
      Spindle.Returns.text
      (let+ _ = Spindle.body_stream ~max:1024 () in
       Ok "")
  in
  let a =
    Spindle.Test.app
      [
        add;
        post "defaults" (Spindle.json note);
        post "raw" Spindle.body;
        stream;
      ]
  in
  let j = json_of_doc (Spindle.App.app a) in
  List.iter
    (fun (what, path, target) ->
      let refused =
        Spindle_http.Status.equal
          (Spindle.Test.call a `POST target ~body:"").status `Bad_request
      in
      let required =
        match member [ "paths"; path; "post"; "requestBody"; "required" ] j with
        | `Bool b -> b
        | `Null -> false
        | other ->
            Alcotest.failf "%s: required is %s" what
              (Yojson.Safe.to_string other)
      in
      Alcotest.(check bool)
        (Printf.sprintf "%s is required: %b, as an empty one is refused" what
           refused)
        refused required)
    [
      ("a JSON body", "/orders/{order_id}/items", "/orders/1/items");
      ("a JSON body whose members have defaults", "/defaults", "/defaults");
      ("a raw body", "/raw", "/raw");
      ("a body read as it arrives", "/stream", "/stream");
    ]

(* An operation's id is made from its path, and two paths that make one
   id would be one name in a generated client. *)
let test_two_paths_that_make_one_operation_are_refused () =
  let answer path =
    Spindle.get path Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.make "")))
  in
  let a =
    made [ answer Spindle.Path.(s "a-b"); answer Spindle.Path.(s "a_b") ]
  in
  match Spindle.Openapi.document a with
  | Ok _ -> Alcotest.fail "two routes shared an operationId"
  | Error e ->
      Alcotest.(check bool)
        "naming the operation" true
        (List.exists (contains ~sub:"get_a_b") e)

(* Routes told apart by a parameter's type are one path and one method to
   OpenAPI, so they are one operation: its parameter is either type, and it
   reads and answers what either route does. The zod module keys them once. *)
let test_routes_told_apart_by_a_type_are_one_operation () =
  let by_number =
    Spindle.get ~summary:"An item by its number"
      Spindle.Path.(s "items" / Spindle.Path.int ~unparsed:Next_route "key")
      (Spindle.Returns.json item_json)
      (Spindle.Dep.return (Error Spindle.Refusal.not_found))
  and by_name =
    Spindle.get ~summary:"Items by their name" ~refuses:[ gone ]
      Spindle.Path.(s "items" / Spindle.Path.string "key")
      (Spindle.Returns.json (Wiretype.list item_json))
      (let+ _ = Spindle.Query.required "lang" Spindle.Codec.string in
       Error Spindle.Refusal.not_found)
  in
  let a = made [ by_number; by_name ] in
  let j = json_of_doc a in
  let keys path = Yojson.Safe.Util.keys (member path j) in
  Alcotest.(check (list string))
    "one path" [ "/items/{key}" ] (keys [ "paths" ]);
  Alcotest.(check (list string))
    "one operation" [ "get" ]
    (keys [ "paths"; "/items/{key}" ]);
  let op = member [ "paths"; "/items/{key}"; "get" ] j in
  Alcotest.(check string)
    "both summaries" "An item by its number; Items by their name"
    (str [ "summary" ] op);
  Alcotest.(check (list string))
    "the parameter either type, and the query one route reads, not required"
    [ "key:path:true:integer|string"; "lang:query:false:string" ]
    (List.map
       (fun p ->
         let schema = member [ "schema" ] p in
         let types =
           match member [ "anyOf" ] schema with
           | `List alts -> String.concat "|" (List.map (str [ "type" ]) alts)
           | _ -> str [ "type" ] schema
         in
         String.concat ":"
           [
             str [ "name" ] p;
             str [ "in" ] p;
             Yojson.Safe.to_string (member [ "required" ] p);
             types;
           ])
       (Yojson.Safe.Util.to_list (member [ "parameters" ] op)));
  Alcotest.(check (list string))
    "either answer"
    [ "#/components/schemas/Item"; "array" ]
    (List.map
       (fun alt ->
         match member [ "$ref" ] alt with
         | `String r -> r
         | _ -> str [ "type" ] alt)
       (Yojson.Safe.Util.to_list
          (member
             [
               "responses";
               "200";
               "content";
               "application/json";
               "schema";
               "anyOf";
             ]
             op)));
  Alcotest.(check bool)
    "and the refusal one route declares" true
    (contains ~sub:"gone" (str [ "responses"; "410"; "description" ] op));
  match Spindle.Zod.schemas a with
  | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)
  | Ok ts ->
      let entry = {|"GET /items/{key}": {|} in
      let rec count from =
        let n = String.length entry in
        if from + n > String.length ts then 0
        else if String.equal (String.sub ts from n) entry then
          1 + count (from + n)
        else count (from + 1)
      in
      Alcotest.(check int) "zod keys the route once" 1 (count 0);
      Alcotest.(check bool)
        "with either answer" true
        (contains ~sub:"z.union(" ts)

(* OpenAPI names a parameter once at its place in a path, so two routes
   whose paths differ only in a parameter's name are refused, whatever
   their methods, rather than written as two paths it counts as one. *)
let test_one_path_with_two_names_is_refused () =
  let answer route path =
    route path Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.make "")))
  in
  let a =
    made
      [
        answer Spindle.get Spindle.Path.(s "items" / Spindle.Path.int "id");
        answer Spindle.delete Spindle.Path.(s "items" / Spindle.Path.int "item");
      ]
  in
  match Spindle.Openapi.document a with
  | Ok _ -> Alcotest.fail "one path was written under two names"
  | Error e ->
      Alcotest.(check bool)
        "naming both, and what to do" true
        (List.exists
           (fun m ->
             contains ~sub:"GET /items/{id}" m
             && contains ~sub:"DELETE /items/{item}" m
             && contains ~sub:"give them one name" m)
           e)

(* One operation answers one way: a page beside a value is refused, since
   neither printer can say which request gets which. *)
let test_one_operation_that_answers_two_ways_is_refused () =
  let by_number =
    Spindle.get
      Spindle.Path.(s "items" / Spindle.Path.int ~unparsed:Next_route "key")
      (Spindle.Returns.json item_json)
      (Spindle.Dep.return (Error Spindle.Refusal.not_found))
  and by_name =
    Spindle.get
      Spindle.Path.(s "items" / Spindle.Path.string "key")
      Spindle.Returns.html
      (Spindle.Dep.return (Ok "<p>an item</p>"))
  in
  match Spindle.Openapi.document (made [ by_number; by_name ]) with
  | Ok _ -> Alcotest.fail "one operation answered two ways"
  | Error e ->
      Alcotest.(check bool)
        "naming the operation, and why" true
        (List.exists
           (fun m ->
             contains ~sub:"GET /items/{key}" m
             && contains ~sub:"answer in different ways" m)
           e)

(* Each status a route may answer is its own response in the document, with
   when it happens, and the zod entry lists them beside the one body. *)
let test_each_status_is_a_response () =
  let upsert =
    Spindle.put
      Spindle.Path.(s "items" / Spindle.Path.string "name")
      (Spindle.Returns.json_response item_json
         ~statuses:
           [ (`Created, "The item was made."); (`OK, "The item was replaced.") ])
      (Spindle.Dep.return (Error Spindle.Refusal.not_found))
  in
  let a = made [ upsert ] in
  let responses =
    member [ "paths"; "/items/{name}"; "put"; "responses" ] (json_of_doc a)
  in
  Alcotest.(check string)
    "made" "The item was made."
    (str [ "201"; "description" ] responses);
  Alcotest.(check string)
    "replaced" "The item was replaced."
    (str [ "200"; "description" ] responses);
  Alcotest.(check bool)
    "each with the body" true
    (member [ "200"; "content"; "application/json"; "schema" ] responses
    <> `Null);
  match Spindle.Zod.schemas a with
  | Ok text ->
      Alcotest.(check bool)
        "zod lists them" true
        (contains ~sub:"statuses: [201, 200]" text)
  | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)

let test_the_zod_schemas_say_the_same () =
  match Spindle.Zod.schemas described with
  | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)
  | Ok ts ->
      List.iter
        (fun sub -> Alcotest.(check bool) sub true (contains ~sub ts))
        [
          {|import { z } from "zod/mini";|};
          "export const ItemSchema = z.object({";
          {|size: z.enum(["small", "large"]),|};
          "note: z.optional(z.nullable(z.string())),";
          "/** What it is called. */";
          "export type Item = z.infer<typeof ItemSchema>;";
          {|"gone",|};
          {|"POST /orders/{order_id}/items": {|};
          "answer: { status: 201, schema: ItemSchema },";
        ]

(* The Melange client: a function per route a function can call, named by
   its operation, and an error wherever two names in the module would be
   one. How a shape is printed is wiretype's suite's, and calling the server
   is test/melange's. *)

let client_of routes = Spindle.Melange.client (made routes)

let refused_naming ~sub = function
  | Ok _ -> Alcotest.fail "printed where two names are one"
  | Error e ->
      Alcotest.(check bool) ("says " ^ sub) true (List.exists (contains ~sub) e)

let test_the_melange_client_says_the_same () =
  match Spindle.Melange.client described with
  | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)
  | Ok ml ->
      List.iter
        (fun sub -> Alcotest.(check bool) sub true (contains ~sub ml))
        [
          "and item = {";
          "module Route = struct";
          "(** Add an item *)";
          "let post_orders_order_id_items ?origin ~order_id ?page ?weight \
           ?limit ?since ?after ?x_request ~body () =";
          "(Route.value [ 201 ] decode_item)";
        ]

type beats

let test_a_stream_s_events_are_a_variant () =
  let tick : (int, beats) Spindle.Event.kind =
    Spindle.Event.json "tick" Wiretype.int
  and line : (string, beats) Spindle.Event.kind = Spindle.Event.text "line" in
  match
    client_of
      [
        Spindle.get
          Spindle.Path.(s "ticks")
          (Spindle.Returns.events Spindle.Event.[ declare tick; declare line ])
          (Spindle.Dep.return (Ok (fun _ -> Ok ())));
      ]
  with
  | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)
  | Ok ml ->
      List.iter
        (fun sub -> Alcotest.(check bool) sub true (contains ~sub ml))
        [
          "type get_ticks_event = Tick of get_ticks_tick_data | Line of string";
          "let get_ticks ?origin ~on_event () =";
          "Route.Stream.call";
        ]

(* A browser's WebSocket sends no header of the page's choosing. *)
let test_a_socket_reading_a_header_has_no_function () =
  let chat = Spindle.Websocket.(protocol ~client:text ~server:text ()) in
  match
    client_of
      [
        Spindle.get
          Spindle.Path.(s "chat")
          (Spindle.Returns.websocket chat)
          (let+ _ = Spindle.Header.required "x-room" Spindle.Codec.string in
           Ok (fun _ -> Ok ()));
        Spindle.get
          Spindle.Path.(s "open")
          (Spindle.Returns.websocket chat)
          (Spindle.Dep.return (Ok (fun _ -> Ok ())));
      ]
  with
  | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)
  | Ok ml ->
      Alcotest.(check (pair bool bool))
        "none for the one with a header, one for the other" (false, true)
        (contains ~sub:"let get_chat " ml, contains ~sub:"let get_open " ml)

let test_two_labels_of_one_name_are_refused () =
  refused_naming ~sub:"GET /things takes two inputs labelled body"
    (client_of
       [
         Spindle.get
           Spindle.Path.(s "things")
           (Spindle.Returns.json item_json)
           (let+ _ = Spindle.Query.optional "body" Spindle.Codec.string
            and+ i = Spindle.json item_json in
            Ok i);
       ])

let test_an_operation_named_as_a_function_is_refused () =
  let get_a =
    Wiretype.Object.map ~kind:"get a" Fun.id
    |> Wiretype.Object.mem "x" Wiretype.int ~enc:Fun.id
    |> Wiretype.Object.finish
  in
  refused_naming ~sub:"the operation get_a_of_json, a name the module has"
    (client_of
       [
         Spindle.get
           Spindle.Path.(s "a" / s "of" / s "json")
           (Spindle.Returns.json get_a)
           (Spindle.Dep.return (Ok 1));
       ])

let test_a_component_named_as_a_route_s_is_refused () =
  let answer =
    Wiretype.Object.map ~kind:"get items answer" Fun.id
    |> Wiretype.Object.mem "x" Wiretype.int ~enc:Fun.id
    |> Wiretype.Object.finish
  in
  refused_naming ~sub:"two components are both get_items_answer"
    (client_of
       [
         Spindle.get
           Spindle.Path.(s "items")
           (Spindle.Returns.json (Wiretype.list item_json))
           (Spindle.Dep.return (Ok []));
         Spindle.get
           Spindle.Path.(s "other")
           (Spindle.Returns.json answer)
           (Spindle.Dep.return (Ok 1));
       ])

(* Every body that is refused for its type says 415 in the document: what
   the route answers and what it says it answers are one list. *)
let test_a_body_refused_for_its_type_says_415 () =
  let route path dep =
    Spindle.post
      Spindle.Path.(s path)
      (Spindle.Returns.empty ())
      (let+ _ = dep in
       Ok ())
  in
  let routes =
    [
      ( "json",
        true,
        route "json" (Spindle.Dep.map ignore (Spindle.json item_json)) );
      ( "form",
        true,
        route "form"
          (Spindle.Form.required "x" Spindle.Codec.string
          |> Spindle.Dep.map ignore) );
      ( "parts",
        true,
        route "parts" (Spindle.Dep.map ignore (Spindle.multipart ~max:1024 ()))
      );
      ( "stream",
        true,
        route "stream"
          (Spindle.Dep.map ignore
             (Spindle.body_stream ~content_types:[ "text/csv" ] ~max:1024 ()))
      );
      ("raw", false, route "raw" (Spindle.Dep.map ignore Spindle.body));
    ]
  in
  let a = Spindle.Test.app (List.map (fun (_, _, r) -> r) routes) in
  let doc = json_of_doc (Spindle.App.app a) in
  List.iter
    (fun (path, refuses, _) ->
      Alcotest.(check bool)
        (Printf.sprintf "/%s says 415: %b" path refuses)
        refuses
        (member [ "paths"; "/" ^ path; "post"; "responses"; "415" ] doc <> `Null);
      if refuses then
        Alcotest.(check int)
          (Printf.sprintf "and /%s answers it" path)
          415
          (Spindle_http.Status.to_int
             (Spindle.Test.call a `POST ("/" ^ path)
                ~headers:[ ("content-type", "text/plain") ]
                ~body:"x")
               .status))
    routes;
  Alcotest.(check (list string))
    "a stream's types are its body's content" [ "text/csv" ]
    (match
       member [ "paths"; "/stream"; "post"; "requestBody"; "content" ] doc
     with
    | `Assoc members -> List.map fst members
    | _ -> []);
  Alcotest.(check (list string))
    "and a raw body's, of any type, is bytes"
    [ "application/octet-stream" ]
    (match member [ "paths"; "/raw"; "post"; "requestBody"; "content" ] doc with
    | `Assoc members -> List.map fst members
    | _ -> [])

(* Nothing is described as its status alone, in the document and the
   module alike, where a response of the route's own could say only that it
   is one. *)
let test_nothing_is_said_as_its_status () =
  let quiet =
    Spindle.post
      Spindle.Path.(s "quiet")
      (Spindle.Returns.empty ())
      (Spindle.Dep.return (Ok ()))
  in
  let a = made [ quiet ] in
  let op = member [ "paths"; "/quiet"; "post" ] (json_of_doc a) in
  Alcotest.(check string)
    "204, and what it means" "No content."
    (str [ "responses"; "204"; "description" ] op);
  Alcotest.(check bool)
    "with no content" true
    (Yojson.Safe.equal `Null (member [ "responses"; "204"; "content" ] op));
  match Spindle.Zod.schemas a with
  | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)
  | Ok ts ->
      Alcotest.(check bool)
        "the module says the status" true
        (contains ~sub:"answer: { status: 204 }," ts)

(* The document and the reference over it are the application's own, and
   the reference asks no other host for anything. *)
let test_docs_are_served_from_here () =
  let a =
    Spindle.Test.app (add :: Spindle.Openapi.routes ~title:"Orders" [ add ])
  in
  let get path = Spindle.Test.call a `GET path in
  let doc = get "/openapi.json" in
  Alcotest.(check int)
    "the document" 200
    (Spindle_http.Status.to_int doc.status);
  Alcotest.(check bool)
    "of the app without itself" false
    (contains ~sub:"/openapi.json" doc.body);
  let page = get "/docs" in
  Alcotest.(check int)
    "the reference" 200
    (Spindle_http.Status.to_int page.status);
  Alcotest.(check bool)
    "with scripts of its own" true
    (contains ~sub:{|<script src="/docs/scalar.js">|} page.body
    && not (contains ~sub:"https://" page.body));
  let script = get "/docs/scalar.js" in
  Alcotest.(check int)
    "and the script, here" 200
    (Spindle_http.Status.to_int script.status);
  Alcotest.(check bool) "all of it" true (String.length script.body > 1_000_000)

(* The page names the document and its scripts where they are served, so
   moving one moves what the page asks for. *)
let test_docs_can_be_moved () =
  let a =
    Spindle.Test.app
      (add
      :: Spindle.Openapi.routes
           ~at:Spindle.Path.(s "reference")
           ~document:Spindle.Path.(s "api.json")
           [ add ])
  in
  let get path = Spindle.Test.call a `GET path in
  Alcotest.(check int)
    "the document" 200
    (Spindle_http.Status.to_int (get "/api.json").status);
  Alcotest.(check int)
    "and nothing where it was" 404
    (Spindle_http.Status.to_int (get "/openapi.json").status);
  let page = (get "/reference").body in
  Alcotest.(check bool)
    "the page names both" true
    (contains ~sub:{|data-url="/api.json"|} page
    && contains ~sub:{|<script src="/reference/scalar.js">|} page);
  Alcotest.(check int)
    "and its script is beneath it" 200
    (Spindle_http.Status.to_int (get "/reference/scalar.js").status)

(* A page at a parameter is no one place, and it is written in source. *)
let test_a_mistake_in_the_docs_raises () =
  match
    Spindle.Openapi.routes
      ~at:Spindle.Path.(s "docs" / string "version")
      [ add ]
  with
  | _ -> Alcotest.fail "docs at a parameter were served"
  | exception Invalid_argument m ->
      Alcotest.(check bool)
        "saying whose" true
        (contains ~sub:"Spindle.Openapi.routes" m)

type ticks

(* A stream is described an item per event as a browser parses it: its name
   a constant, JSON data said to be JSON of its description, and text data
   the string every event's data is. *)
let test_a_stream_is_described_by_its_events () =
  let tick : (int, ticks) Spindle.Event.kind =
    Spindle.Event.json "tick" Wiretype.int
  in
  let line : (string, ticks) Spindle.Event.kind = Spindle.Event.text "line" in
  let ticks =
    Spindle.get
      Spindle.Path.(s "ticks")
      (Spindle.Returns.events Spindle.Event.[ declare tick; declare line ])
      (Spindle.Dep.return (Ok (fun _ -> Ok ())))
  in
  let item =
    member
      [
        "paths";
        "/ticks";
        "get";
        "responses";
        "200";
        "content";
        "text/event-stream";
        "itemSchema";
      ]
      (json_of_doc (made [ ticks ]))
  in
  let branches = Yojson.Safe.Util.to_list (member [ "oneOf" ] item) in
  Alcotest.(check (list string))
    "an item per event" [ "tick"; "line" ]
    (List.map (str [ "properties"; "event"; "const" ]) branches);
  match branches with
  | [ tick; line ] ->
      Alcotest.(check string)
        "JSON data is said to be JSON" "application/json"
        (str [ "properties"; "data"; "contentMediaType" ] tick);
      Alcotest.(check string)
        "of its description" "integer"
        (str [ "properties"; "data"; "contentSchema"; "type" ] tick);
      Alcotest.(check bool)
        "text data is only a string" true
        (Yojson.Safe.equal (member [ "properties"; "data" ] line) `Null);
      Alcotest.(check string)
        "as every event's is" "string"
        (str [ "properties"; "data"; "type" ] item)
  | _ -> Alcotest.fail "expected two events"

(* ------------------------------------------------------------------ *)
(* What a description says holds through the framework *)

(* A member the server gives is never read from a request, and one the
   client gives never written into an answer -- through a route as through
   wiretype, and in the document alike. *)
type user = { id : int; name : string; password : string }

let user_json =
  Wiretype.Object.(
    map ~kind:"user" (fun id name password -> { id; name; password })
    |> mem "id" Wiretype.int ~absent:0
         ~enc:(fun u -> u.id)
         ~access:Wiretype.Shape.Read_only
    |> mem "name" Wiretype.string ~enc:(fun u -> u.name)
    |> mem "password" Wiretype.string ~absent:""
         ~enc:(fun u -> u.password)
         ~access:Wiretype.Shape.Write_only
    |> finish)

let test_a_member_s_access_holds_through_a_route () =
  let seen = ref None in
  let add =
    Spindle.post
      Spindle.Path.(s "users")
      (Spindle.Returns.json ~status:`Created user_json)
      (let+ u = Spindle.json user_json in
       seen := Some u;
       Ok { u with id = 7 })
  in
  let a = Spindle.Test.app [ add ] in
  let r =
    Spindle.Test.call a `POST "/users"
      ~headers:[ ("content-type", "application/json") ]
      ~body:{|{"id":99,"name":"kim","password":"s3cret"}|}
  in
  Alcotest.(check int) "created" 201 (Spindle_http.Status.to_int r.status);
  (match !seen with
  | Some u ->
      Alcotest.(check int) "the id a request sent is not read" 0 u.id;
      Alcotest.(check string) "the password is" "s3cret" u.password
  | None -> Alcotest.fail "the route never ran");
  Alcotest.(check string)
    "the answer holds the server's id and never the password"
    {|{"id":7,"name":"kim"}|} r.body;
  let doc = json_of_doc (Spindle.App.app a) in
  let properties path =
    match member (path @ [ "properties" ]) doc with
    | `Assoc members -> List.map fst members
    | _ -> []
  in
  let schema_of ref_path =
    (* A component, or a schema written in place. *)
    match member ref_path doc with
    | `Assoc members -> (
        match List.assoc_opt "$ref" members with
        | Some (`String r) -> (
            match String.split_on_char '/' r with
            | [ "#"; "components"; "schemas"; name ] ->
                [ "components"; "schemas"; name ]
            | _ -> ref_path)
        | _ -> ref_path)
    | _ -> ref_path
  in
  let request =
    schema_of
      [
        "paths";
        "/users";
        "post";
        "requestBody";
        "content";
        "application/json";
        "schema";
      ]
  in
  let answer =
    schema_of
      [
        "paths";
        "/users";
        "post";
        "responses";
        "201";
        "content";
        "application/json";
        "schema";
      ]
  in
  Alcotest.(check (list string))
    "the request's schema has no id" [ "name"; "password" ] (properties request);
  Alcotest.(check (list string))
    "the answer's has no password" [ "id"; "name" ] (properties answer)

(* A value outside its description's bounds is one decode would refuse, so
   it is never written: the route's bug, answered 500 and logged so. *)
let test_a_value_outside_its_bounds_is_the_route_s_bug () =
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let few = Wiretype.int_bounded ~max:10 () in
  let count =
    Spindle.get
      Spindle.Path.(s "count")
      (Spindle.Returns.json few)
      (Spindle.Dep.return (Ok 11))
  in
  let r = Spindle.Test.call (Spindle.Test.app [ count ]) `GET "/count" in
  Alcotest.(check int) "500" 500 (Spindle_http.Status.to_int r.status);
  Alcotest.(check bool)
    "nothing of the value answered" false
    (contains ~sub:"11" r.body);
  Alcotest.(check bool)
    "an error line saying why" true
    (List.exists
       (fun l ->
         contains ~sub:{|"level":"error"|} l && contains ~sub:"out_of_bounds" l)
       !lines)

(* A resource is the program's, supplied at start, and no request carries
   it: a route that reads one is described as the route that does not. *)
let test_a_resource_is_no_input () =
  let database : string Spindle.Dep.t = Spindle.Dep.of_resource "database" in
  let app reads =
    made
      [
        Spindle.get ~summary:"One order"
          Spindle.Path.(s "orders" / order_id)
          Spindle.Returns.text reads;
      ]
  in
  let plain =
    app
      (let+ _ = Spindle.param order_id in
       Ok "")
  and reading =
    app
      (let+ _ = Spindle.param order_id and+ _ = database in
       Ok "")
  in
  let printed a =
    match
      ( Spindle.Openapi.document ~title:"Orders" ~version:"1" a,
        Spindle.Zod.schemas a )
    with
    | Ok document, Ok schemas -> document ^ schemas
    | Error e, _ | _, Error e -> Alcotest.fail (String.concat "; " e)
  in
  Alcotest.(check string) "the same" (printed plain) (printed reading)

let () =
  Alcotest.run "openapi"
    [
      ( "what a description says",
        [
          Alcotest.test_case "a member's access holds through a route" `Quick
            test_a_member_s_access_holds_through_a_route;
          Alcotest.test_case "a value outside its bounds is the route's bug"
            `Quick test_a_value_outside_its_bounds_is_the_route_s_bug;
        ] );
      ( "the document",
        [
          Alcotest.test_case "each status is a response" `Quick
            test_each_status_is_a_response;
          Alcotest.test_case "a route is in the document" `Quick
            test_a_route_is_in_the_document;
          Alcotest.test_case "a stream is described by its events" `Quick
            test_a_stream_is_described_by_its_events;
          Alcotest.test_case "a credential is said once" `Quick
            test_a_credential_is_said_once;
          Alcotest.test_case "a credential says whether it is needed" `Quick
            test_a_credential_says_whether_it_is_needed;
          Alcotest.test_case "what is loose is reported" `Quick
            test_what_is_loose_is_reported;
          Alcotest.test_case "two paths that make one operation are refused"
            `Quick test_two_paths_that_make_one_operation_are_refused;
          Alcotest.test_case "routes told apart by a type are one operation"
            `Quick test_routes_told_apart_by_a_type_are_one_operation;
          Alcotest.test_case "one path with two names is refused" `Quick
            test_one_path_with_two_names_is_refused;
          Alcotest.test_case "one operation that answers two ways is refused"
            `Quick test_one_operation_that_answers_two_ways_is_refused;
          Alcotest.test_case "two reads of one input are one parameter" `Quick
            test_two_reads_of_one_input_are_one_parameter;
          Alcotest.test_case "a body is required where an empty one is refused"
            `Quick test_a_body_is_required_where_an_empty_one_is_refused;
          Alcotest.test_case "nothing is said as its status" `Quick
            test_nothing_is_said_as_its_status;
          Alcotest.test_case "a body refused for its type says 415" `Quick
            test_a_body_refused_for_its_type_says_415;
          Alcotest.test_case "a resource is no input" `Quick
            test_a_resource_is_no_input;
        ] );
      ( "the module",
        [
          Alcotest.test_case "the zod schemas say the same" `Quick
            test_the_zod_schemas_say_the_same;
        ] );
      ( "the melange client",
        [
          Alcotest.test_case "it says the same" `Quick
            test_the_melange_client_says_the_same;
          Alcotest.test_case "a stream's events are a variant" `Quick
            test_a_stream_s_events_are_a_variant;
          Alcotest.test_case "a socket reading a header has no function" `Quick
            test_a_socket_reading_a_header_has_no_function;
          Alcotest.test_case "two labels of one name are refused" `Quick
            test_two_labels_of_one_name_are_refused;
          Alcotest.test_case "an operation named as a function is refused"
            `Quick test_an_operation_named_as_a_function_is_refused;
          Alcotest.test_case "a component named as a route's is refused" `Quick
            test_a_component_named_as_a_route_s_is_refused;
        ] );
      ( "docs",
        [
          Alcotest.test_case "served from here" `Quick
            test_docs_are_served_from_here;
          Alcotest.test_case "moved" `Quick test_docs_can_be_moved;
          Alcotest.test_case "a mistake raises" `Quick
            test_a_mistake_in_the_docs_raises;
        ] );
    ]
