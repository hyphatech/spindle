(* Access control: a policy decides, a dependency enforces. A notes API
   where an owner reads and deletes a note, a shared one is read by anyone
   signed in, a locked one is deleted by nobody, and an admin does anything
   but delete a locked note. *)

open Spindle.Syntax
module Access = Spindle.Access

type user = { id : int; admin : bool }
type note = { owner : int; text : string; shared : bool; locked : bool }

let users =
  [
    (1, { id = 1; admin = false });
    (2, { id = 2; admin = false });
    (3, { id = 3; admin = true });
  ]

let notes =
  [
    (1, { owner = 1; text = "Write to Charles"; shared = false; locked = false });
    (2, { owner = 2; text = "Fix the bombe"; shared = true; locked = false });
    (3, { owner = 1; text = "Keep this"; shared = false; locked = true });
  ]

let signed_out =
  Spindle.Refusal.Code.make "signed_out" ~status:`Unauthorized ~challenge:"User"
    ~doc:"Nobody is signed in."

(* How many times a request read its caller, so a test can say once. *)
let callers_read = Atomic.make 0

let me =
  Access.principal
    ~id:(fun u -> string_of_int u.id)
    (Spindle.Dep.join ~refuses:[ signed_out ]
       (let+ id = Spindle.Header.optional "x-user" Wiretype.int in
        Atomic.incr callers_read;
        match Option.bind id (fun id -> List.assoc_opt id users) with
        | Some u -> Ok u
        | None -> Error (Spindle.Refusal.make signed_out "Sign in first.")))

type action = Read | Delete

let rule user action note =
  match action with
  | Read when note.shared || note.owner = user.id || user.admin -> Access.Allow
  | Delete when note.locked -> Access.Deny "locked"
  | Delete when note.owner = user.id || user.admin -> Access.Allow
  | Read | Delete -> Access.Deny "not the owner"

let action_name = function Read -> "read" | Delete -> "delete"
let policy = Access.policy "notes" me ~action:action_name rule
let note_id = Spindle.Path.param "note_id" Wiretype.int

let note =
  Access.resource policy
    (Spindle.Dep.join
       ~refuses:[ Spindle.Refusal.Code.not_found ]
       (let+ id = Spindle.param note_id in
        Option.to_result ~none:Spindle.Refusal.not_found
          (List.assoc_opt id notes)))

type admin = Use

let admin =
  Access.policy "admin" me
    ~action:(function Use -> "use")
    (fun user Use () ->
      if user.admin then Access.Allow else Access.Deny "no admin")

let gone =
  Spindle.Refusal.Code.make "gone_note" ~status:`Forbidden
    ~doc:"Not a note of yours."

let routes =
  [
    Spindle.get
      Spindle.Path.(s "notes" / note_id)
      Spindle.Returns.text
      (let+ n = Access.can Read note in
       Ok n.text);
    Spindle.delete
      Spindle.Path.(s "notes" / note_id)
      (Spindle.Returns.empty ~status:`No_content ())
      (let+ _ = Access.can Delete note in
       Ok ());
    Spindle.put
      Spindle.Path.(s "notes" / note_id / s "seal")
      Spindle.Returns.text
      (let+ n =
         Access.can Delete note
           ~deny_as:(Spindle.Refusal.make gone "That note is not yours.")
       in
       Ok n.text);
    (* two checks of one note: the caller and the note are read once *)
    Spindle.get
      Spindle.Path.(s "notes" / note_id / s "twice")
      Spindle.Returns.text
      (let+ n = Access.can Read note and+ _ = Access.can Read note in
       Ok n.text);
    Spindle.get
      Spindle.Path.(s "admin")
      Spindle.Returns.text
      (let+ () = Access.require admin Use in
       Ok "the switchboard");
    (* a note named in the body, as a tool's arguments name one *)
    Spindle.post
      Spindle.Path.(s "deletions")
      Spindle.Returns.text
      (let+ checked = Access.check policy and+ id = Spindle.json Wiretype.int in
       match List.assoc_opt id notes with
       | None -> Error Spindle.Refusal.not_found
       | Some n ->
           let* n = checked Delete n in
           Ok n.text);
  ]

let app = Spindle.Test.app ~refuses:[ Spindle.Refusal.Code.not_found ] routes

let call ?user meth target =
  let headers =
    match user with Some id -> [ ("x-user", string_of_int id) ] | None -> []
  in
  Spindle.Test.call app meth target ~headers

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || go (i + 1))
  in
  go 0

let check_status what expected (r : Spindle.Test.response) =
  Alcotest.(check int)
    what
    (Spindle.Status.to_int expected)
    (Spindle.Status.to_int r.status)

let captured f =
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Debug)
    ~out:(fun l -> lines := l :: !lines)
    ();
  f ();
  List.rev_map Yojson.Safe.from_string !lines

let field name line =
  match Yojson.Safe.Util.member name line with `String s -> Some s | _ -> None

let denials lines =
  List.filter (fun l -> Option.is_some (field "spindle.access.policy" l)) lines

(* Scenario 1: only the owner deletes, and not a locked note. *)

let test_the_owner_deletes () =
  check_status "the owner" `No_content (call ~user:1 `DELETE "/notes/1")

let test_a_locked_note_is_deleted_by_nobody () =
  check_status "its owner" `Not_found (call ~user:1 `DELETE "/notes/3");
  check_status "an admin" `Not_found (call ~user:3 `DELETE "/notes/3")

let test_nobody_signed_in_is_asked_to_sign_in_first () =
  check_status "no caller" `Unauthorized (call `DELETE "/notes/1");
  check_status "before the note is looked up" `Unauthorized
    (call `DELETE "/notes/99")

let test_a_shared_note_is_read_by_anyone_signed_in () =
  check_status "not its owner" `OK (call ~user:1 `GET "/notes/2")

let test_a_denial_writes_one_line () =
  let lines = captured (fun () -> ignore (call ~user:2 `DELETE "/notes/1")) in
  match denials lines with
  | [ l ] ->
      let says what expected =
        Alcotest.(check (option string)) what (Some expected) (field what l)
      in
      says "spindle.access.policy" "notes";
      says "spindle.access.action" "delete";
      says "spindle.access.subject" "2";
      says "spindle.access.reason" "not the owner";
      says "http.route" "/notes/{note_id}";
      Alcotest.(check (option string)) "at warn" (Some "warn") (field "level" l)
  | other -> Alcotest.failf "%d denial lines" (List.length other)

let test_an_allow_writes_no_line () =
  let lines = captured (fun () -> ignore (call ~user:1 `DELETE "/notes/1")) in
  Alcotest.(check int) "no denial line" 0 (List.length (denials lines))

let test_a_denial_may_be_a_refusal_of_the_routes_own () =
  let r = call ~user:2 `PUT "/notes/1/seal" in
  check_status "its status" `Forbidden r;
  Alcotest.(check bool) "its code" true (contains ~sub:"gone_note" r.body)

let test_two_checks_read_the_caller_once () =
  Atomic.set callers_read 0;
  check_status "read" `OK (call ~user:1 `GET "/notes/1/twice");
  Alcotest.(check int) "the caller, once" 1 (Atomic.get callers_read)

(* Scenario 4: a policy is tested without a server. *)

let test_a_policy_is_decided_without_a_server () =
  let ada = List.assoc 1 users and alan = List.assoc 2 users in
  let adas = List.assoc 1 notes in
  let decided = function Access.Allow -> "allow" | Access.Deny r -> r in
  Alcotest.(check string)
    "the owner" "allow"
    (decided (Access.decide policy ada Delete adas));
  Alcotest.(check string)
    "another" "not the owner"
    (decided (Access.decide policy alan Delete adas))

(* Scenario 6: a route with no object. *)

let test_check_judges_an_object_named_in_the_body () =
  let post user id =
    Spindle.Test.call app `POST "/deletions"
      ~headers:
        [ ("x-user", string_of_int user); ("content-type", "application/json") ]
      ~body:(string_of_int id)
  in
  check_status "the owner" `OK (post 1 1);
  let lines =
    captured (fun () -> check_status "another" `Forbidden (post 2 1))
  in
  Alcotest.(check int) "one denial line" 1 (List.length (denials lines))

(* Scenario 3, as far as a route's own codes go: what a check refuses with is
   declared, so the document lists it. *)

let codes_of meth pattern =
  match
    List.find_opt
      (fun r ->
        let i = Spindle.Route.info r in
        Spindle.Meth.equal i.meth meth && String.equal i.pattern pattern)
      routes
  with
  | Some r -> List.map Spindle.Refusal.Code.name (Spindle.Route.info r).codes
  | None -> Alcotest.failf "no route %s" pattern

let test_a_check_declares_what_it_refuses_with () =
  let has what code codes =
    Alcotest.(check bool) what true (List.exists (String.equal code) codes)
  in
  has "can" "not_found" (codes_of `DELETE "/notes/{note_id}");
  has "the caller" "signed_out" (codes_of `DELETE "/notes/{note_id}");
  has "deny_as" "gone_note" (codes_of `PUT "/notes/{note_id}/seal");
  has "require" "forbidden" (codes_of `GET "/admin");
  has "check" "forbidden" (codes_of `POST "/deletions")

(* Scenario 2: a route that says nobody may call it does not start. *)

let undeclared =
  Spindle.get
    Spindle.Path.(s "forgotten")
    Spindle.Returns.text
    (Spindle.Dep.return (Ok "anyone's"))

let refused_with routes =
  match Spindle.App.make routes with
  | Ok _ -> Alcotest.fail "the routes were made"
  | Error m -> m

let test_a_route_that_declares_nobody_does_not_start () =
  let m = refused_with [ undeclared ] in
  Alcotest.(check bool)
    "names the route" true
    (contains ~sub:"GET /forgotten" m);
  Alcotest.(check bool) "says what to do" true (contains ~sub:"Access.public" m)

let test_a_test_app_raises_for_one () =
  match Spindle.Test.app [ undeclared ] with
  | _ -> Alcotest.fail "the app was made"
  | exception Invalid_argument m ->
      Alcotest.(check bool)
        "names the route" true
        (contains ~sub:"GET /forgotten" m)

let test_a_public_route_starts () =
  let a = Spindle.Test.app [ Access.public undeclared ] in
  check_status "anyone" `OK (Spindle.Test.call a `GET "/forgotten")

let test_a_public_route_that_reads_a_caller_does_not_start () =
  let m =
    refused_with
      [
        Access.public
          (Spindle.get
             Spindle.Path.(s "mine")
             Spindle.Returns.text
             (let+ _ = Access.caller me in
              Ok "mine"));
      ]
  in
  Alcotest.(check bool) "names the route" true (contains ~sub:"GET /mine" m)

let said (a : Spindle.Route.access) =
  match a with
  | Public -> "public"
  | Caller -> "caller"
  | Checked { policy; action = Some action } -> policy ^ ":" ^ action
  | Checked { policy; action = None } -> policy

let access_of meth pattern =
  match
    List.find_opt
      (fun r ->
        let i = Spindle.Route.info r in
        Spindle.Meth.equal i.meth meth && String.equal i.pattern pattern)
      routes
  with
  | Some r -> List.map said (Spindle.Route.info r).access
  | None -> Alcotest.failf "no route %s" pattern

let test_a_route_lists_who_may_call_it () =
  let lists what expected got =
    Alcotest.(check (list string)) what expected got
  in
  lists "can"
    [ "caller"; "notes:delete" ]
    (access_of `DELETE "/notes/{note_id}");
  lists "can, twice" [ "caller"; "notes:read" ]
    (access_of `GET "/notes/{note_id}/twice");
  lists "require" [ "caller"; "admin:use" ] (access_of `GET "/admin");
  lists "check" [ "caller"; "notes" ] (access_of `POST "/deletions");
  lists "public" [ "public" ]
    (List.map said (Spindle.Route.info (Access.public undeclared)).access)

(* The framework's own routes are as public as the API they serve, unless
   given a guard, which then says who may call them. *)

let test_the_frameworks_routes_are_public () =
  let made what routes =
    match Spindle.App.make routes with
    | Ok _ -> ()
    | Error m -> Alcotest.failf "%s: %s" what m
  in
  made "the document" (Spindle.Openapi.routes ~title:"Notes" routes);
  made "the probes" (Spindle.Health.routes []);
  made "the metrics" (Spindle.Metrics.routes (Spindle.Metrics.create ()));
  made "the resource's metadata"
    [
      Spindle.Bearer.metadata
        (Spindle.Bearer.make ~issuer:"https://id.example.com"
           ~resource:"https://notes.example.com")
        routes;
    ]

let test_a_guard_says_who_may_call () =
  let each what expected routes =
    List.iter
      (fun r ->
        Alcotest.(check (list string))
          what expected
          (List.map said (Spindle.Route.info r).access))
      routes
  in
  let admins = Access.require admin Use in
  each "the probes, an admin's" [ "caller"; "admin:use" ]
    (Spindle.Health.routes ~guard:admins []);
  each "the metrics, an admin's" [ "caller"; "admin:use" ]
    (Spindle.Metrics.routes ~guard:admins (Spindle.Metrics.create ()));
  each "the document, an admin's" [ "caller"; "admin:use" ]
    (Spindle.Openapi.routes ~guard:admins routes);
  each "a guard that checks nobody: as public as before" [ "public" ]
    (Spindle.Health.routes
       ~guard:
         (let+ _ = Spindle.Header.optional "x-probe" Wiretype.string in
          ())
       [])

let test_files_are_anyones () =
  List.iter
    (fun (what, r) ->
      Alcotest.(check (list string))
        what [ "public" ]
        (List.map said (Spindle.Route.info r).access))
    [
      ("a site's files", Spindle.Static.directory "public");
      ("a directory's", Spindle.Files.directory "uploads");
    ]

let test_a_token_is_a_caller () =
  let auth =
    Spindle.Bearer.make ~issuer:"https://id.example.com"
      ~resource:"https://notes.example.com"
  in
  let reads what d =
    Alcotest.(check (list string))
      what [ "caller" ]
      (List.map said
         (Spindle.Route.info
            (Spindle.get Spindle.Path.root Spindle.Returns.text
               (let+ _ = d in
                Ok "")))
           .access)
  in
  reads "its claims" (Spindle.Bearer.claims auth);
  reads "a scope of it" (Spindle.Bearer.scope auth "notes:read")

(* Scenario 5: an agent's call is checked as a person's would be. A tool's
   refusal is its own error, which the model reads, and no other tool's. *)

type named = { note : int }

let named =
  Wiretype.Object.(
    map (fun note -> { note })
    |> mem "note" Wiretype.int ~enc:(fun n -> n.note)
    |> finish)

let delete_note =
  Spindle_mcp.tool "delete_note" named Wiretype.string
    (let+ checked = Access.check policy in
     fun n ->
       match List.assoc_opt n.note notes with
       | None -> Error Spindle.Refusal.not_found
       | Some note ->
           let* note = checked Delete note in
           Ok note.text)

let echo =
  Spindle_mcp.tool "echo" named Wiretype.int
    (Spindle.Dep.return (fun n -> Ok n.note))

let tools =
  lazy
    (Spindle.Test.app
       (Spindle_mcp.routes ~name:"notes" ~version:"1" [ delete_note; echo ]))

let tool ?user name note =
  let r =
    Spindle_mcp.Test.call (Lazy.force tools) "tools/call"
      ~headers:
        (match user with
        | Some id -> [ ("x-user", string_of_int id) ]
        | None -> [])
      [
        ("name", Wiretype.Value.String name);
        ( "arguments",
          Wiretype.Value.Object [ ("note", Wiretype.Value.Number (float note)) ]
        );
      ]
  in
  let result =
    Yojson.Safe.Util.member "result" (Yojson.Safe.from_string r.body)
  in
  ( Yojson.Safe.Util.member "isError" result,
    Yojson.Safe.to_string (Yojson.Safe.Util.member "content" result) )

let test_a_tool_checks_the_person_behind_the_call () =
  let failed (is_error, _) = match is_error with `Bool b -> b | _ -> false in
  let says sub (_, content) = contains ~sub content in
  let owner = tool ~user:1 "delete_note" 1 in
  Alcotest.(check bool) "the owner" false (failed owner);
  Alcotest.(check bool) "with the note" true (says "Write to Charles" owner);
  let lines = ref [] in
  let other = ref (`Null, "") in
  lines := captured (fun () -> other := tool ~user:2 "delete_note" 1);
  Alcotest.(check bool) "another person" true (failed !other);
  Alcotest.(check bool) "told no" true (says "You may not do that." !other);
  Alcotest.(check int) "one denial line" 1 (List.length (denials !lines));
  let nobody = tool "delete_note" 1 in
  Alcotest.(check bool) "nobody" true (failed nobody);
  Alcotest.(check bool) "asked to sign in" true (says "Sign in first." nobody)

let test_a_tools_refusal_is_its_own () =
  let is_error, content = tool "echo" 7 in
  Alcotest.(check bool)
    "another tool, for nobody" true
    (match is_error with `Bool b -> not b | _ -> true);
  Alcotest.(check bool) "answered" true (contains ~sub:"7" content)

(* Scenario 3: the document says who may call each operation. *)

let document =
  lazy
    (match Spindle.App.make (Access.public undeclared :: routes) with
    | Error m -> Alcotest.fail m
    | Ok a -> (
        match Spindle.Openapi.document ~title:"Notes" ~version:"1" a with
        | Ok text -> Yojson.Safe.from_string text
        | Error e -> Alcotest.failf "no document: %s" (String.concat "; " e)))

let operation meth at =
  List.fold_left
    (fun j k -> Yojson.Safe.Util.member k j)
    (Lazy.force document) [ "paths"; at; meth ]

let test_the_document_lists_each_check () =
  let access meth path =
    Yojson.Safe.to_string
      (Yojson.Safe.Util.member "x-spindle-access" (operation meth path))
  in
  Alcotest.(check string)
    "can" {|[{"policy":"notes","action":"delete"}]|}
    (access "delete" "/notes/{note_id}");
  Alcotest.(check string)
    "require" {|[{"policy":"admin","action":"use"}]|} (access "get" "/admin");
  Alcotest.(check string)
    "check" {|[{"policy":"notes"}]|}
    (access "post" "/deletions");
  Alcotest.(check string) "public" "null" (access "get" "/forgotten")

(* ------------------------------------------------------------------ *)
(* OWASP ASVS 5.0, V8 Authorization: a row a requirement Spindle meets,
   named by its number. Field-level rules (8.1.2, 8.2.3), a tenant's
   (8.4.1) and context's (8.1.3, 8.1.4, 8.2.4, 8.4.2) are the
   application's: a policy reads them as it reads an owner. *)

(* 8.1.1: authorization documentation defines function-level and
   data-specific rules. The document is that documentation, generated:
   every operation that is not public names who may call it. *)
let test_8_1_1_the_document_says_who_may_call_each_operation () =
  let paths =
    Yojson.Safe.Util.to_assoc
      (Yojson.Safe.Util.member "paths" (Lazy.force document))
  in
  List.iter
    (fun (path, operations) ->
      List.iter
        (fun (meth, operation) ->
          let declared =
            match Yojson.Safe.Util.member "x-spindle-access" operation with
            | `List _ -> true
            | _ -> false
          in
          Alcotest.(check bool)
            (meth ^ " " ^ path)
            (not (String.equal path "/forgotten"))
            declared)
        (Yojson.Safe.Util.to_assoc operations))
    paths

(* 8.2.1: function-level access is restricted to consumers with explicit
   permissions -- and a function nobody gave a permission to does not
   start. *)
let test_8_2_1_a_function_needs_an_explicit_permission () =
  let r = call ~user:1 `GET "/admin" in
  check_status "without the permission" `Forbidden r;
  Alcotest.(check bool) "forbidden" true (contains ~sub:{|"forbidden"|} r.body);
  check_status "with it" `OK (call ~user:3 `GET "/admin");
  Alcotest.(check bool)
    "a function that names no permission does not start" true
    (contains ~sub:"declares nobody" (refused_with [ undeclared ]))

(* 8.2.2: data-specific access is restricted to consumers with explicit
   permissions to the item, against IDOR and BOLA: every id guessed is
   answered as a missing one, so guessing learns nothing. *)
let test_8_2_2_an_object_needs_a_permission_to_it () =
  let missing = call ~user:2 `DELETE "/notes/99" in
  List.iter
    (fun id ->
      let r = call ~user:2 `DELETE (Printf.sprintf "/notes/%d" id) in
      check_status (Printf.sprintf "note %d" id) `Not_found r;
      Alcotest.(check string)
        (Printf.sprintf "note %d, as a missing one" id)
        missing.body r.body)
    [ 1; 3; 4; 5 ]

(* 8.3.1: rules are enforced at a trusted layer, not by anything a client
   could manipulate: no header, spelling of a path or method reaches the
   object without its check. *)
let test_8_3_1_nothing_a_client_sends_skips_a_check () =
  let as_one ?(headers = []) meth target =
    Spindle.Test.call app meth target ~headers:(("x-user", "1") :: headers)
  in
  check_status "a shared note, read" `OK (as_one `GET "/notes/2");
  check_status "deleted under another method's name" `Not_found
    (as_one `DELETE "/notes/2" ~headers:[ ("x-http-method-override", "GET") ]);
  check_status "its id percent-encoded" `Not_found (as_one `DELETE "/notes/%32");
  check_status "a trailing slash" `Not_found (as_one `DELETE "/notes/2/");
  check_status "read by HEAD" `Not_found
    (Spindle.Test.call app `HEAD "/notes/1" ~headers:[ ("x-user", "2") ])

(* 8.3.2: a change to what a decision reads applies at once: a role
   removed refuses the very next request. *)
let admins = Atomic.make [ 1 ]

let staff =
  Access.principal ~id:string_of_int
    (Spindle.Dep.join ~refuses:[ signed_out ]
       (let+ id = Spindle.Header.optional "x-user" Wiretype.int in
        Option.to_result id
          ~none:(Spindle.Refusal.make signed_out "Sign in first.")))

let console =
  Access.policy "console" staff
    ~action:(function Use -> "use")
    (fun id Use () ->
      (* What the store said as this request read it. *)
      if List.mem id (Atomic.get admins) then Access.Allow
      else Access.Deny "no admin")

let test_8_3_2_a_role_removed_refuses_the_next_request () =
  let a =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(s "console")
          Spindle.Returns.text
          (let+ () = Access.require console Use in
           Ok "the console");
      ]
  in
  let use () =
    Spindle.Test.call a `GET "/console" ~headers:[ ("x-user", "1") ]
  in
  check_status "an admin" `OK (use ());
  Atomic.set admins [];
  check_status "no longer" `Forbidden (use ());
  Atomic.set admins [ 1 ]

(* 8.3.3: access is decided by the originating subject's permissions, not
   an intermediary's: a tool called by an agent is judged as the person
   the token was issued for, whichever client sends it. *)
let ed_priv, ed_pub =
  Mirage_crypto_rng_unix.use_default ();
  Mirage_crypto_ec.Ed25519.generate ()

let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let key =
  match
    Spindle_http.Jwk.of_string
      (Printf.sprintf {|{"kty":"OKP","crv":"Ed25519","x":"%s"}|}
         (b64 (Mirage_crypto_ec.Ed25519.pub_to_octets ed_pub)))
  with
  | Ok k -> k
  | Error e -> Alcotest.fail e

let issuer = "https://id.example.com"
let resource = "https://notes.example.com/mcp"
let auth = Spindle.Bearer.make ~issuer ~resource
let now = Ptime.of_float_s 1792756800. |> Option.value ~default:Ptime.epoch

(* One agent, the same client, sending each person's token. *)
let token ~person =
  let at s = Printf.sprintf "%.0f" (Ptime.to_float_s now +. s) in
  let payload =
    Printf.sprintf
      {|{"iss":%S,"aud":%S,"sub":%S,"client_id":"agent","iat":%s,"exp":%s,"jti":"t","scope":""}|}
      issuer resource person (at (-60.)) (at 300.)
  in
  let input = b64 {|{"alg":"EdDSA","typ":"at+jwt"}|} ^ "." ^ b64 payload in
  input ^ "." ^ b64 (Mirage_crypto_ec.Ed25519.sign ~key:ed_priv input)

let person =
  Access.principal
    ~id:(fun u -> string_of_int u.id)
    (Spindle.Dep.join ~refuses:[ signed_out ]
       (let+ (claims : Spindle.Bearer.claims) = Spindle.Bearer.claims auth in
        Option.to_result
          ~none:(Spindle.Refusal.make signed_out "Sign in first.")
          (Option.bind (int_of_string_opt claims.subject) (fun id ->
               List.assoc_opt id users))))

let by_person = Access.policy "notes" person ~action:action_name rule

let agents_tool =
  Spindle_mcp.tool "delete_note" named Wiretype.string
    (let+ checked = Access.check by_person in
     fun n ->
       match List.assoc_opt n.note notes with
       | None -> Error Spindle.Refusal.not_found
       | Some note ->
           let* note = checked Delete note in
           Ok note.text)

let test_8_3_3_an_agent_is_judged_as_its_person () =
  let a =
    Spindle.Test.app
      ~resources:
        [
          Spindle.Dep.resource (Spindle.Bearer.keys auth) (fun ~kid:_ ->
              [ key ]);
        ]
      (Spindle_mcp.routes ~auth ~name:"notes" ~version:"1" [ agents_tool ])
  in
  let delete person =
    let r =
      Spindle_mcp.Test.call ~now a "tools/call"
        ~headers:[ ("authorization", "Bearer " ^ token ~person) ]
        [
          ("name", Wiretype.Value.String "delete_note");
          ( "arguments",
            Wiretype.Value.Object [ ("note", Wiretype.Value.Number 1.) ] );
        ]
    in
    match
      Yojson.Safe.Util.(
        member "isError" (member "result" (Yojson.Safe.from_string r.body)))
    with
    | `Bool b -> b
    | _ -> false
  in
  Alcotest.(check bool) "the owner, through the agent" false (delete "1");
  let lines =
    captured (fun () ->
        Alcotest.(check bool)
          "another, through the same agent" true (delete "2"))
  in
  match denials lines with
  | [ l ] ->
      Alcotest.(check (option string))
        "decided as the person, not the client" (Some "2")
        (field "spindle.access.subject" l)
  | other -> Alcotest.failf "%d denial lines" (List.length other)

let () =
  Alcotest.run "access"
    [
      ( "ASVS 5.0 V8",
        [
          Alcotest.test_case
            "8.1.1: the document says who may call each operation" `Quick
            test_8_1_1_the_document_says_who_may_call_each_operation;
          Alcotest.test_case "8.2.1: a function needs an explicit permission"
            `Quick test_8_2_1_a_function_needs_an_explicit_permission;
          Alcotest.test_case "8.2.2: an object needs a permission to it" `Quick
            test_8_2_2_an_object_needs_a_permission_to_it;
          Alcotest.test_case "8.3.1: nothing a client sends skips a check"
            `Quick test_8_3_1_nothing_a_client_sends_skips_a_check;
          Alcotest.test_case "8.3.2: a role removed refuses the next request"
            `Quick test_8_3_2_a_role_removed_refuses_the_next_request;
          Alcotest.test_case "8.3.3: an agent is judged as its person" `Quick
            test_8_3_3_an_agent_is_judged_as_its_person;
        ] );
      ( "only the owner deletes",
        [
          Alcotest.test_case "the owner deletes" `Quick test_the_owner_deletes;
          Alcotest.test_case "a locked note is deleted by nobody" `Quick
            test_a_locked_note_is_deleted_by_nobody;
          Alcotest.test_case "nobody signed in is asked to sign in first" `Quick
            test_nobody_signed_in_is_asked_to_sign_in_first;
          Alcotest.test_case "a shared note is read by anyone signed in" `Quick
            test_a_shared_note_is_read_by_anyone_signed_in;
          Alcotest.test_case "a denial writes one line" `Quick
            test_a_denial_writes_one_line;
          Alcotest.test_case "an allow writes no line" `Quick
            test_an_allow_writes_no_line;
          Alcotest.test_case "a denial may be a refusal of the route's own"
            `Quick test_a_denial_may_be_a_refusal_of_the_routes_own;
          Alcotest.test_case "two checks read the caller once" `Quick
            test_two_checks_read_the_caller_once;
          Alcotest.test_case "a check declares what it refuses with" `Quick
            test_a_check_declares_what_it_refuses_with;
        ] );
      ( "a policy without a server",
        [
          Alcotest.test_case "a policy is decided without a server" `Quick
            test_a_policy_is_decided_without_a_server;
        ] );
      ( "who may call",
        [
          Alcotest.test_case "a route that declares nobody does not start"
            `Quick test_a_route_that_declares_nobody_does_not_start;
          Alcotest.test_case "a test app raises for one" `Quick
            test_a_test_app_raises_for_one;
          Alcotest.test_case "a public route starts" `Quick
            test_a_public_route_starts;
          Alcotest.test_case "a public route that reads a caller does not start"
            `Quick test_a_public_route_that_reads_a_caller_does_not_start;
          Alcotest.test_case "a route lists who may call it" `Quick
            test_a_route_lists_who_may_call_it;
          Alcotest.test_case "the framework's routes are public" `Quick
            test_the_frameworks_routes_are_public;
          Alcotest.test_case "files are anyone's" `Quick test_files_are_anyones;
          Alcotest.test_case "a token is a caller" `Quick
            test_a_token_is_a_caller;
          Alcotest.test_case "a guard says who may call" `Quick
            test_a_guard_says_who_may_call;
          Alcotest.test_case "the document lists each check" `Quick
            test_the_document_lists_each_check;
        ] );
      ( "an agent's call",
        [
          Alcotest.test_case "a tool checks the person behind the call" `Quick
            test_a_tool_checks_the_person_behind_the_call;
          Alcotest.test_case "a tool's refusal is its own" `Quick
            test_a_tools_refusal_is_its_own;
        ] );
      ( "an object as a value",
        [
          Alcotest.test_case "check judges an object named in the body" `Quick
            test_check_judges_an_object_named_in_the_body;
        ] );
    ]
