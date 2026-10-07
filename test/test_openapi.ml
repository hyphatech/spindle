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
     and+ i = Spindle.json item_json in
     Ok i)

let described = Spindle.Test.app [ add ]

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
    [ "order_id:path:integer"; "page:query:integer"; "weight:query:number" ]
    (List.map
       (fun p ->
         str [ "name" ] p ^ ":" ^ str [ "in" ] p ^ ":"
         ^ str [ "schema"; "type" ] p)
       params);
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
  let j = json_of_doc (Spindle.Test.app [ keyed ]) in
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
  let j = json_of_doc (Spindle.Test.app [ needs; welcomes ]) in
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
    Spindle.Test.app
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

(* An operation's id is made from its path, and two paths that make one
   id would be one name in a generated client. *)
let test_two_paths_that_make_one_operation_are_refused () =
  let answer path =
    Spindle.get path Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.make "")))
  in
  let a =
    Spindle.Test.app
      [ answer Spindle.Path.(s "a-b"); answer Spindle.Path.(s "a_b") ]
  in
  match Spindle.Openapi.document a with
  | Ok _ -> Alcotest.fail "two routes shared an operationId"
  | Error e ->
      Alcotest.(check bool)
        "naming the operation" true
        (List.exists (contains ~sub:"get_a_b") e)

(* Each status a route may answer is its own response in the document, with
   when it happens, and the zod entry lists them beside the one body. *)
let test_each_status_is_a_response () =
  let upsert =
    Spindle.put
      Spindle.Path.(s "items" / Spindle.Path.str "name")
      (Spindle.Returns.json_response item_json
         ~statuses:
           [ (`Created, "The item was made."); (`OK, "The item was replaced.") ])
      (Spindle.Dep.return (Error Spindle.Refusal.not_found))
  in
  let a = Spindle.Test.app [ upsert ] in
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
  match Spindle.Zod.module_ a with
  | Ok text ->
      Alcotest.(check bool)
        "zod lists them" true
        (contains ~sub:"statuses: [201, 200]" text)
  | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)

let test_the_zod_module_says_the_same () =
  match Spindle.Zod.module_ described with
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
             (Spindle.body_stream ~content_type:(String.equal "text/csv")
                ~max:1024 ())) );
      ("raw", false, route "raw" (Spindle.Dep.map ignore Spindle.body));
    ]
  in
  let a = Spindle.Test.app (List.map (fun (_, _, r) -> r) routes) in
  let doc = json_of_doc a in
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
          (Spindle.Test.call a `POST ("/" ^ path)
             ~headers:[ ("content-type", "text/plain") ]
             ~body:"x")
            .status)
    routes

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
  let a = Spindle.Test.app [ quiet ] in
  let op = member [ "paths"; "/quiet"; "post" ] (json_of_doc a) in
  Alcotest.(check string)
    "204, and what it means" "No content."
    (str [ "responses"; "204"; "description" ] op);
  Alcotest.(check bool)
    "with no content" true
    (Yojson.Safe.equal `Null (member [ "responses"; "204"; "content" ] op));
  match Spindle.Zod.module_ a with
  | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)
  | Ok ts ->
      Alcotest.(check bool)
        "the module says the status" true
        (contains ~sub:"answer: { status: 204 }," ts)

(* The document and the reference over it are the application's own, and
   the reference asks no other host for anything. *)
let test_docs_are_served_from_here () =
  let a =
    Spindle.Test.app (add :: Spindle.Openapi.docs ~title:"Orders" [ add ])
  in
  let get path = Spindle.Test.call a `GET path in
  let doc = get "/openapi.json" in
  Alcotest.(check int) "the document" 200 doc.status;
  Alcotest.(check bool)
    "of the app without itself" false
    (contains ~sub:"/openapi.json" doc.body);
  let page = get "/docs" in
  Alcotest.(check int) "the reference" 200 page.status;
  Alcotest.(check bool)
    "with scripts of its own" true
    (contains ~sub:{|<script src="/docs/scalar.js">|} page.body
    && not (contains ~sub:"https://" page.body));
  let script = get "/docs/scalar.js" in
  Alcotest.(check int) "and the script, here" 200 script.status;
  Alcotest.(check bool) "all of it" true (String.length script.body > 1_000_000)

(* The page names the document and its scripts where they are served, so
   moving one moves what the page asks for. *)
let test_docs_can_be_moved () =
  let a =
    Spindle.Test.app
      (add
      :: Spindle.Openapi.docs
           ~at:Spindle.Path.(s "reference")
           ~document:Spindle.Path.(s "api.json")
           [ add ])
  in
  let get path = Spindle.Test.call a `GET path in
  Alcotest.(check int) "the document" 200 (get "/api.json").status;
  Alcotest.(check int)
    "and nothing where it was" 404 (get "/openapi.json").status;
  let page = (get "/reference").body in
  Alcotest.(check bool)
    "the page names both" true
    (contains ~sub:{|data-url="/api.json"|} page
    && contains ~sub:{|<script src="/reference/scalar.js">|} page);
  Alcotest.(check int)
    "and its script is beneath it" 200 (get "/reference/scalar.js").status

(* A page at a parameter is no one place, and it is written in source. *)
let test_a_mistake_in_the_docs_raises () =
  match
    Spindle.Openapi.docs ~at:Spindle.Path.(s "docs" / str "version") [ add ]
  with
  | _ -> Alcotest.fail "docs at a parameter were served"
  | exception Invalid_argument m ->
      Alcotest.(check bool)
        "saying whose" true
        (contains ~sub:"Spindle.Openapi.docs" m)

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
      (json_of_doc (Spindle.Test.app [ ticks ]))
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

let () =
  Alcotest.run "openapi"
    [
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
          Alcotest.test_case "nothing is said as its status" `Quick
            test_nothing_is_said_as_its_status;
          Alcotest.test_case "a body refused for its type says 415" `Quick
            test_a_body_refused_for_its_type_says_415;
        ] );
      ( "the module",
        [
          Alcotest.test_case "the zod module says the same" `Quick
            test_the_zod_module_says_the_same;
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
