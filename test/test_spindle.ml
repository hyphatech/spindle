(* The web framework, through its in-process client: no socket, no port.

   What is pinned here is what an application relies on without reading the
   framework's source -- that a route is one value, that a refusal never
   carries its detail to the client, that a cookie is Secure wherever it
   can be, and that the framework knows nothing about the application it
   serves. *)

open Spindle.Syntax

(* A code of the test's own, declared where a refusal is made from it. *)
let code name status =
  (* A 401 names how to authenticate, as every one must. *)
  let challenge =
    match status with `Unauthorized -> Some {|Test realm="t"|} | _ -> None
  in
  Spindle.Refusal.Code.make ?challenge name ~status ~doc:"A test's."

let check_status = Alcotest.(check int)
let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)
let check_header = Alcotest.(check (option string))

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || go (i + 1))
  in
  go 0

exception Boom of string

type greeting = { name : string; times : int }

let greeting_json =
  Wiretype.Object.map ~kind:"greeting" (fun name times -> { name; times })
  |> Wiretype.Object.mem "name" Wiretype.string ~absent:"nobody" ~enc:(fun g ->
      g.name)
  |> Wiretype.Object.mem "times" Wiretype.int ~absent:1 ~enc:(fun g -> g.times)
  |> Wiretype.Object.finish

let name = Spindle.Path.str "name"

let hello =
  Spindle.get
    Spindle.Path.(s "hello" / name)
    Spindle.Returns.response
    (let+ name = Spindle.param name in
     Ok (Spindle.Response.json greeting_json { name; times = 1 }))

let echo =
  Spindle.post
    Spindle.Path.(s "echo")
    Spindle.Returns.response
    (let+ g = Spindle.json greeting_json in
     Ok (Spindle.Response.json ~status:`Created greeting_json g))

(* ------------------------------------------------------------------ *)
(* Routes *)

let test_path_parameter_reaches_the_handler () =
  let r = Spindle.Test.call (Spindle.Test.app [ hello ]) `GET "/hello/kim" in
  check_status "ok" 200 r.status;
  check_string "the parameter, encoded" {|{"name":"kim","times":1}|} r.body;
  check_header "json" (Some "application/json")
    (Spindle.Test.header r "content-type")

let test_two_routes_claiming_one_path_are_refused () =
  match Spindle.App.make [ hello; hello ] with
  | Ok _ -> Alcotest.fail "a second route for GET /hello could never answer"
  | Error m ->
      Alcotest.(check bool)
        "names the method and path" true
        (contains ~sub:"GET /hello" m)

let test_the_same_path_under_two_methods_is_fine () =
  let other =
    Spindle.delete
      Spindle.Path.(s "hello" / name)
      Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.empty ())))
  in
  let a = Spindle.Test.app [ hello; other ] in
  check_status "GET" 200 (Spindle.Test.call a `GET "/hello/kim").status;
  check_status "DELETE" 204 (Spindle.Test.call a `DELETE "/hello/kim").status

let test_wrong_method_is_405_with_allow () =
  let r = Spindle.Test.call (Spindle.Test.app [ hello ]) `POST "/hello/kim" in
  check_status "405" 405 r.status;
  check_header "allow, HEAD with GET" (Some "GET, HEAD")
    (Spindle.Test.header r "allow")

let test_unknown_path_is_404_or_the_not_found_answer () =
  let r = Spindle.Test.call (Spindle.Test.app [ hello ]) `GET "/nowhere" in
  check_status "404" 404 r.status;
  check_string "a code and a sentence"
    {|{"error":"not_found","message":"There is nothing here."}|} r.body;
  let not_found _ = Spindle.Response.html ~status:`Not_found "a page" in
  let r =
    Spindle.Test.call (Spindle.Test.app ~not_found [ hello ]) `GET "/nowhere"
  in
  check_status "at the status it gives" 404 r.status;
  check_string "the application's page answers" "a page" r.body;
  let site =
    Spindle.get
      Spindle.Path.(root / rest "file")
      Spindle.Returns.text
      (Spindle.Dep.return (Ok "the site"))
  in
  let behind_a_site = Spindle.Test.app ~not_found [ hello; site ] in
  check_string "a rest route at the root takes every path" "the site"
    (Spindle.Test.call behind_a_site `GET "/a/b").body;
  check_status "and every other method there is 405" 405
    (Spindle.Test.call behind_a_site `POST "/a/b").status

let test_head_is_get_without_the_body () =
  let r = Spindle.Test.call (Spindle.Test.app [ hello ]) `HEAD "/hello/kim" in
  check_status "ok" 200 r.status;
  check_string "no body" "" r.body

(* Nothing is an answer of its own: no body and no type, at 204 unless the
   route says otherwise, and a cookie the endpoint set still goes with it. *)
let test_nothing_is_an_answer () =
  let flag = Spindle.Cookie.named "flag" Spindle.Codec.string in
  let quiet =
    Spindle.post
      Spindle.Path.(s "quiet")
      (Spindle.Returns.empty ())
      (let+ set_cookie = Spindle.set_cookie in
       set_cookie (Spindle.Cookie.make flag "on");
       Ok ())
  in
  let later =
    Spindle.post
      Spindle.Path.(s "later")
      (Spindle.Returns.empty ~status:`Accepted ())
      (Spindle.Dep.return (Ok ()))
  in
  let a = Spindle.Test.app [ quiet; later ] in
  let r = Spindle.Test.call a `POST "/quiet" in
  check_status "204" 204 r.status;
  check_string "no body" "" r.body;
  check_header "no type" None (Spindle.Test.header r "content-type");
  Alcotest.(check bool)
    "the cookie it set" true
    (Option.is_some (Spindle.Test.header r "set-cookie"));
  check_status "the status it says" 202
    (Spindle.Test.call a `POST "/later").status

(* A segment arrives as the text it stands for, not as the URL spelled it. *)
let test_a_segment_is_decoded () =
  let r =
    Spindle.Test.call (Spindle.Test.app [ hello ]) `GET "/hello/Kim%20Li"
  in
  check_string "decoded" {|{"name":"Kim Li","times":1}|} r.body

let test_a_trailing_slash_is_another_path () =
  check_status "strict, unless asked" 404
    (Spindle.Test.call (Spindle.Test.app [ hello ]) `GET "/hello/kim/").status;
  let redirecting =
    Spindle.Test.app ~trailing_slash:Spindle.App.Redirect [ hello ]
  in
  let r = Spindle.Test.call redirecting `GET "/hello/kim/?x=1" in
  check_status "asked: redirected, the method kept" 308 r.status;
  check_header "to the path without it, and its query" (Some "/hello/kim?x=1")
    (Spindle.Test.header r "location");
  check_status "and never to another host" 404
    (Spindle.Test.call redirecting `GET "//elsewhere.example/hello/kim/").status;
  check_status "nor through a backslash, which a browser reads as a slash" 404
    (Spindle.Test.call redirecting `GET "/\\elsewhere.example/hello/kim/")
      .status

(* The fields the framework writes from what an answer carries are no
   headers for a route to write beside them: a second content type is two
   answers to one question, and a cookie written as a header would miss
   the Secure decision. *)
let test_a_header_the_framework_writes_is_the_routes_bug () =
  let answering headers =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(s "own")
          Spindle.Returns.response
          (Spindle.Dep.return (Ok (Spindle.Response.make ~headers "x")));
      ]
  in
  List.iter
    (fun (name, value) ->
      check_status
        (name ^ " is the route's bug")
        500 (Spindle.Test.call (answering [ (name, value) ]) `GET "/own").status)
    [
      ("content-type", "text/html");
      ("Set-Cookie", "a=b");
      ("date", "now");
      ("x-request-id", "mine");
    ];
  let r = Spindle.Test.call (answering [ ("x-mine", "1") ]) `GET "/own" in
  check_status "a header of the route's own is written" 200 r.status;
  check_header "beside it" (Some "1") (Spindle.Test.header r "x-mine");
  check_int "and the content type once" 1
    (List.length
       (List.filter (fun (k, _) -> String.equal k "content-type") r.headers))

(* The root is "/", which is no segment at all -- not one empty segment,
   which no route has. *)
let test_the_root_answers_slash () =
  let home =
    Spindle.get Spindle.Path.root Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.make "home")))
  in
  let r = Spindle.Test.call (Spindle.Test.app [ home; hello ]) `GET "/" in
  check_status "found" 200 r.status;
  check_string "the root's own" "home" r.body;
  check_status "and nothing else is it" 404
    (Spindle.Test.call (Spindle.Test.app [ home ]) `GET "//").status

(* ------------------------------------------------------------------ *)
(* Bodies *)

let test_absent_body_reads_as_an_empty_object () =
  let r = Spindle.Test.call (Spindle.Test.app [ echo ]) `POST "/echo" in
  check_status "created" 201 r.status;
  check_string "every default" {|{"name":"nobody","times":1}|} r.body

let test_body_is_decoded () =
  let r =
    Spindle.Test.call
      (Spindle.Test.app [ echo ])
      `POST "/echo" ~body:{|{"name":"lee","times":3}|}
  in
  check_string "round trip" {|{"name":"lee","times":3}|} r.body

(* Where the shape failed is a problem the client is told, at its place,
   with its code and a sentence of its own. *)
let test_malformed_body_is_a_sentence_without_its_detail () =
  let r =
    Spindle.Test.call
      (Spindle.Test.app [ echo ])
      `POST "/echo" ~body:{|{"times":"many"}|}
  in
  check_status "400" 400 r.status;
  check_string "a problem at the member"
    {|{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"body.times","code":"unexpected_type","message":"This must be a whole number, not text."}]}|}
    r.body;
  Alcotest.(check bool)
    "and at the body, when it is not JSON at all" true
    (contains ~sub:{|"at":"body","code"|}
       (Spindle.Test.call
          (Spindle.Test.app [ echo ])
          `POST "/echo" ~body:"not json")
         .body)

let test_a_raise_is_500_and_says_nothing_of_it () =
  let boom =
    Spindle.get
      Spindle.Path.(s "boom")
      Spindle.Returns.response
      (let+ () = Spindle.Dep.return () in
       raise (Boom "the database password is hunter2"))
  in
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let r = Spindle.Test.call (Spindle.Test.app [ boom ]) `GET "/boom" in
  check_status "500" 500 r.status;
  Alcotest.(check bool)
    "the exception is not in the body" false
    (contains ~sub:"hunter2" r.body);
  (* The line an error tracker groups by: what was raised, and where. *)
  match List.find_opt (contains ~sub:{|"error.kind":|}) !lines with
  | None -> Alcotest.fail "no line says what was raised"
  | Some line ->
      List.iter
        (fun sub -> Alcotest.(check bool) sub true (contains ~sub line))
        [
          {|"level":"error"|};
          {|Boom"|};
          {|"error.message":"|};
          {|"error.stack":"|};
          {|"url.path":"/boom"|};
          {|"http.route":"/boom"|};
          {|"spindle.refusal.code":"internal"|};
        ]

(* ------------------------------------------------------------------ *)
(* Middleware *)

(* The first listed is outermost: it sees the request first and the
   response last, in the order the list is read. *)
let test_middleware_runs_in_the_order_listed () =
  let trace = ref [] in
  let say what = trace := what :: !trace in
  let marked name handler req =
    say (name ^ " in");
    let r = handler req in
    say (name ^ " out");
    r
  in
  let seen =
    Spindle.get
      Spindle.Path.(s "seen")
      Spindle.Returns.response
      (Spindle.Dep.of_request (fun _ ->
           say "handler";
           Ok (Ok (Spindle.Response.empty ()))))
  in
  ignore
    (Spindle.Test.call
       (Spindle.Test.app ~middleware:[ marked "a"; marked "b" ] [ seen ])
       `GET "/seen");
  Alcotest.(check (list string))
    "outermost first"
    [ "a in"; "b in"; "handler"; "b out"; "a out" ]
    (List.rev !trace)

(* A middleware may answer by itself -- a maintenance switch -- and the
   handler never runs. *)
let test_middleware_may_answer_alone () =
  let ran = ref false in
  let shut = code "closed" `Service_unavailable in
  let closed _handler _req =
    Spindle.Response.refusal
      (Spindle.Refusal.make shut "We are closed for a moment.")
  in
  let seen =
    Spindle.get
      Spindle.Path.(s "seen")
      Spindle.Returns.response
      (Spindle.Dep.of_request (fun _ ->
           ran := true;
           Ok (Ok (Spindle.Response.empty ()))))
  in
  let r =
    Spindle.Test.call
      (Spindle.Test.app ~middleware:[ closed ] ~codes:[ shut ] [ seen ])
      `GET "/seen"
  in
  check_status "its own answer" 503 r.status;
  Alcotest.(check bool) "and the handler never ran" false !ran

(* A middleware's bug is one request's 500, as a handler's is. *)
let test_a_middleware_that_raises_is_500 () =
  let broken _handler _req = raise (Boom "the key is hunter2") in
  let r =
    Spindle.Test.call
      (Spindle.Test.app ~middleware:[ broken ] [ hello ])
      `GET "/hello/kim"
  in
  check_status "500" 500 r.status;
  Alcotest.(check bool)
    "the exception is not in the body" false
    (contains ~sub:"hunter2" r.body)

(* A middleware can ask the request which route it matched, so a policy for
   some routes reads the route -- here, a key only the limited route carries
   -- and it hears when no route answers at all. *)
let test_middleware_can_ask_the_route () =
  let limited : int Spindle.Meta.key = Spindle.Meta.key () in
  let told = ref [] in
  let tell handler req =
    let response = handler req in
    let what =
      match Spindle.Route.matched req with
      | None -> "none"
      | Some (i : Spindle.Route.info) -> (
          match Spindle.Meta.find limited i.meta with
          | Some n -> Printf.sprintf "%s, limited to %d" i.pattern n
          | None -> i.pattern)
    in
    told := what :: !told;
    response
  in
  let limit =
    Spindle.get
      ~meta:Spindle.Meta.(empty |> add limited 5)
      Spindle.Path.(s "limited")
      Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.empty ())))
  in
  let a =
    Spindle.Test.app ~middleware:[ tell ] ~trailing_slash:Spindle.App.Redirect
      ~not_found:(fun _ -> Spindle.Response.make "a page")
      [ hello; limit ]
  in
  let told_for meth path =
    told := [];
    ignore (Spindle.Test.call a meth path);
    match !told with [ what ] -> what | _ -> "told more than once"
  in
  check_string "a route" "/hello/{name}" (told_for `GET "/hello/kim");
  check_string "its key" "/limited, limited to 5" (told_for `GET "/limited");
  check_string "a 405" "none" (told_for `POST "/limited");
  check_string "a redirect" "none" (told_for `GET "/limited/");
  check_string "the not-found answer" "none" (told_for `GET "/about")

(* Headers for every answer reach an endpoint, the not-found answer and the
   framework's own refusals, and never override a route's own. *)
let test_headers_reach_every_answer () =
  let own =
    Spindle.get
      Spindle.Path.(s "own")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok (Spindle.Response.make ~headers:[ ("x-frame", "route") ] "mine")))
  in
  let page _ = Spindle.Response.make ~content_type:"text/html" "<p>page</p>" in
  let a =
    Spindle.Test.app
      ~middleware:
        [
          Spindle.Middleware.headers [ ("x-frame", "every"); ("x-kind", "all") ];
        ]
      ~not_found:page [ hello; own ]
  in
  let header r = Spindle.Test.header r "x-kind" in
  check_header "an endpoint" (Some "all")
    (header (Spindle.Test.call a `GET "/hello/kim"));
  check_header "a page" (Some "all")
    (header (Spindle.Test.call a `GET "/about"));
  check_header "a refusal" (Some "all")
    (header (Spindle.Test.call a `POST "/hello/kim"));
  check_header "a route's own header wins" (Some "route")
    (Spindle.Test.header (Spindle.Test.call a `GET "/own") "x-frame")

(* ------------------------------------------------------------------ *)
(* Dependencies *)

let test_dependencies_stop_at_the_first_refusal () =
  let asked = ref 0 in
  let counted =
    Spindle.Dep.of_request (fun _ ->
        incr asked;
        Ok ())
  in
  let no =
    Spindle.Dep.refuse
      (Spindle.Refusal.make (code "no" `Forbidden) "You may not.")
  in
  let route =
    Spindle.get
      Spindle.Path.(s "guarded")
      Spindle.Returns.response
      (let+ () = counted and+ () = no and+ () = counted in
       Ok (Spindle.Response.empty ()))
  in
  let r = Spindle.Test.call (Spindle.Test.app [ route ]) `GET "/guarded" in
  check_status "the refusal answers" 403 r.status;
  check_int "left to right, and no further" 1 !asked

(* The body is the last thing read: a refusal that needs no body answers
   first, wherever it is listed, and the body is never asked for. *)
let test_a_refusal_before_the_body_never_reads_it () =
  let signed_in =
    Spindle.Dep.of_request
      ~needs:[ Spindle.Dep.Custom { name = "session"; doc = "a cookie" } ]
      ~refuses:[ code "signed_out" `Unauthorized ]
      (fun r ->
        match Spindle.Request.cookie r "session" with
        | Some s -> Ok s
        | None ->
            Error
              (Spindle.Refusal.make
                 (code "signed_out" `Unauthorized)
                 "Please sign in."))
  in
  let route =
    Spindle.post
      Spindle.Path.(s "post")
      Spindle.Returns.response
      (let+ g = Spindle.json greeting_json and+ _ = signed_in in
       Ok (Spindle.Response.json greeting_json g))
  in
  let read = ref 0 in
  let body =
    {
      Spindle.Body.whole =
        (fun () ->
          incr read;
          Ok {|{"name":"kim"}|});
      part = (fun ~max:_ -> Ok `End);
    }
  in
  let call headers =
    fst
      (Spindle.App.handle
         (Spindle.Test.app [ route ])
         (Spindle.Request.make ~headers ~now:(fun () -> 0) `POST "/post")
         ~body)
  in
  check_status "signed out, first" 401
    (Spindle.Status.to_int (Spindle.Response.status (call [])));
  check_int "and the body never read" 0 !read;
  check_status "signed in" 200
    (Spindle.Status.to_int
       (Spindle.Response.status (call [ ("cookie", "session=s") ])));
  check_int "read once" 1 !read

(* [bind] waits for its left side's value, so what it reads next may be
   the body; it still reads it only once. *)
let test_bind_after_the_body_reads_it () =
  let route =
    Spindle.post
      Spindle.Path.(s "twice")
      Spindle.Returns.response
      (Spindle.Dep.bind Spindle.body (fun first ->
           let+ again = Spindle.body in
           Ok (Spindle.Response.make (first ^ again))))
  in
  let r =
    Spindle.Test.call (Spindle.Test.app [ route ]) `POST "/twice" ~body:"ab"
  in
  check_string "both sides saw the body" "abab" r.body

let test_a_dependency_says_what_it_reads () =
  let listed =
    let+ _ = Spindle.Query.optional "page" Spindle.Codec.int
    and+ _ = Spindle.json greeting_json
    and+ _ =
      Spindle.Cookie.optional
        (Spindle.Cookie.named "session" Spindle.Codec.string)
    and+ _ = Spindle.now in
    ()
  in
  let names =
    List.map
      (function
        | Spindle.Dep.Path n -> "path " ^ n
        | Spindle.Dep.Query i -> "query " ^ i.name
        | Spindle.Dep.Header i -> "header " ^ i.name
        | Spindle.Dep.Cookie i -> "cookie " ^ i.name
        | Spindle.Dep.Field i -> "field " ^ i.name
        | Spindle.Dep.File f -> "file " ^ f.name
        | Spindle.Dep.Body Spindle.Dep.Form -> "form"
        | Spindle.Dep.Body Spindle.Dep.Multipart -> "parts"
        | Spindle.Dep.Body Spindle.Dep.Raw -> "body"
        | Spindle.Dep.Body (Spindle.Dep.Json _) -> "json"
        | Spindle.Dep.Body Spindle.Dep.Stream -> "stream"
        | Spindle.Dep.Custom { name; _ } -> name)
      (Spindle.Dep.needs listed)
  in
  Alcotest.(check (list string))
    "in the order listed"
    [ "query page"; "json"; "cookie session" ]
    names;
  Alcotest.(check bool) "and nothing else" false (Spindle.Dep.opaque listed);
  Alcotest.(check bool)
    "a bind may read more" true
    (Spindle.Dep.opaque
       (Spindle.Dep.bind Spindle.now (fun _ ->
            Spindle.Query.optional "q" Spindle.Codec.string)));
  Alcotest.(check bool)
    "as may a dependency that did not say" true
    (Spindle.Dep.opaque (Spindle.Dep.of_request (fun _ -> Ok ())))

(* A dependency that counts how often it ran. *)
let counting () =
  let ran = ref 0 in
  ( ran,
    Spindle.Dep.of_request ~needs:[] (fun _ ->
        incr ran;
        Ok !ran) )

let answer inputs =
  Spindle.get
    Spindle.Path.(s "shared")
    Spindle.Returns.text
    (let+ s = inputs in
     Ok s)

let test_a_dependency_runs_once_per_request () =
  let ran, user = counting () in
  let checked = Spindle.Dep.join (Spindle.Dep.map (fun n -> Ok n) user) in
  let quota = Spindle.Dep.map (fun n -> n * 10) checked in
  let app =
    Spindle.Test.app
      [
        answer
          (let+ a = checked and+ b = quota and+ c = user in
           Printf.sprintf "%d %d %d" a b c);
      ]
  in
  let r = Spindle.Test.call app `GET "/shared" in
  check_string "every use is given the one answer" "1 10 1" r.body;
  check_int "and it ran once" 1 !ran;
  ignore (Spindle.Test.call app `GET "/shared");
  check_int "once per request" 2 !ran

let test_uncached_runs_at_every_use () =
  let ran, inner = counting () in
  let late = ref 0 in
  let each =
    Spindle.Dep.uncached
      (Spindle.Dep.map
         (fun n ->
           incr late;
           n)
         inner)
  in
  let app =
    Spindle.Test.app
      [
        answer
          (let+ a = each and+ b = each and+ c = inner in
           Printf.sprintf "%d %d %d" a b c);
      ]
  in
  ignore (Spindle.Test.call app `GET "/shared");
  check_int "worked out at every use" 2 !late;
  check_int "and what it is made of shared" 1 !ran

let test_a_body_dependency_is_read_once () =
  let parsed = ref 0 in
  let upper =
    Spindle.Dep.of_body ~need:Spindle.Dep.Raw (fun s ->
        incr parsed;
        Ok (String.uppercase_ascii s))
  in
  let route =
    Spindle.post
      Spindle.Path.(s "shared")
      Spindle.Returns.text
      (let+ a = upper and+ b = Spindle.Dep.map String.length upper in
       Ok (Printf.sprintf "%s %d" a b))
  in
  let r =
    Spindle.Test.call (Spindle.Test.app [ route ]) `POST "/shared" ~body:"ab"
  in
  check_string "both uses saw it" "AB 2" r.body;
  check_int "parsed once" 1 !parsed

let test_an_input_read_twice_is_one_input () =
  let page = Spindle.Query.required "page" Spindle.Codec.int in
  let next = Spindle.Dep.map succ page in
  let inputs =
    let+ p = page and+ n = next in
    Printf.sprintf "%d %d" p n
  in
  check_int "listed once" 1 (List.length (Spindle.Dep.needs inputs));
  let app = Spindle.Test.app [ answer inputs ] in
  check_string "and read once" "1 2"
    (Spindle.Test.call app `GET "/shared?page=1").body;
  let r = Spindle.Test.call app `GET "/shared?page=x" in
  check_status "a problem" 400 r.status;
  let problems =
    match Yojson.Safe.from_string r.body with
    | `Assoc members -> (
        match List.assoc_opt "problems" members with
        | Some (`List ps) -> List.length ps
        | Some _ | None -> 0)
    | _ -> 0
  in
  check_int "reported once" 1 problems;
  let session = Spindle.Dep.credential ~scheme:"session" page in
  check_int "a credential read twice is one credential" 1
    (List.length
       (Spindle.Dep.credentials
          (let+ _ = session and+ _ = session in
           ())))

(* What a [bind]'s function names is the value named outside it; what it
   makes is made for this request. *)
let test_a_bind_shares_what_it_names () =
  let ran, named = counting () in
  let made = ref 0 in
  let inputs =
    Spindle.Dep.bind named (fun first ->
        let fresh =
          Spindle.Dep.of_request ~needs:[] (fun _ ->
              incr made;
              Ok ())
        in
        let+ again = named and+ () = fresh and+ () = fresh in
        Printf.sprintf "%d %d" first again)
  in
  let app = Spindle.Test.app [ answer inputs ] in
  check_string "one answer inside and out" "1 1"
    (Spindle.Test.call app `GET "/shared").body;
  check_int "the named value ran once" 1 !ran;
  check_int "and a made one once, where it was made" 1 !made;
  ignore (Spindle.Test.call app `GET "/shared");
  check_int "made again for the next request" 2 !made

let test_query_header_cookie_and_clock () =
  let route =
    Spindle.get
      Spindle.Path.(s "who")
      Spindle.Returns.response
      (let+ q = Spindle.Query.optional "q" Spindle.Codec.string
       and+ h = Spindle.Header.optional "X-Thing" Spindle.Codec.string
       and+ c =
         Spindle.Cookie.optional (Spindle.Cookie.named "b" Spindle.Codec.string)
       and+ now = Spindle.now in
       Ok
         (Spindle.Response.json
            Wiretype.(list string)
            [
              Option.value q ~default:"-";
              Option.value h ~default:"-";
              Option.value c ~default:"-";
              string_of_int now;
            ]))
  in
  let r =
    Spindle.Test.call
      (Spindle.Test.app [ route ])
      `GET "/who?q=1" ~now:42
      ~headers:[ ("x-thing", "2"); ("cookie", "a=1; b=3"); ("cookie", "c=4") ]
  in
  check_string "all four" {|["1","2","3","42"]|} r.body

(* A default stands in for an input that is absent, and only then: a value
   given is read, and one that does not parse is refused. *)
let test_a_default_stands_in_for_an_absent_input () =
  let route =
    Spindle.get
      Spindle.Path.(s "page")
      Spindle.Returns.text
      (let+ page = Spindle.Query.default "page" Spindle.Codec.int 1
       and+ size = Spindle.Header.default "x-size" Spindle.Codec.int 20 in
       Ok (Printf.sprintf "%d %d" page size))
  in
  let app = Spindle.Test.app [ route ] in
  check_string "both absent" "1 20" (Spindle.Test.call app `GET "/page").body;
  check_string "both given" "3 50"
    (Spindle.Test.call app `GET "/page?page=3" ~headers:[ ("x-size", "50") ])
      .body;
  check_status "one that does not parse" 400
    (Spindle.Test.call app `GET "/page?page=x").status

(* ------------------------------------------------------------------ *)
(* Cookies *)

let with_cookie =
  Spindle.post
    Spindle.Path.(s "in")
    Spindle.Returns.response
    (Spindle.Dep.return
       (Ok
          (Spindle.Response.empty
             ~cookies:
               [
                 Spindle.Cookie.make ~path:"/in" ~max_age:60
                   (Spindle.Cookie.named "k" Spindle.Codec.string)
                   "v";
               ]
             ())))

let set_cookie ?proxied ?(headers = []) () =
  Spindle.Test.header
    (Spindle.Test.call
       (Spindle.Test.app [ with_cookie ])
       `POST "/in" ?proxied ~headers)
    "set-cookie"

(* The exact spelling, because a browser is what reads it and the one
   attribute that silently fails is the one this decides. *)
let test_cookie_is_secure_except_on_loopback () =
  check_header "a real host"
    (Some "k=v; Path=/in; HttpOnly; Secure; SameSite=Lax; Max-Age=60")
    (set_cookie ~headers:[ ("host", "getsente.io") ] ());
  check_header "loopback"
    (Some "k=v; Path=/in; HttpOnly; SameSite=Lax; Max-Age=60")
    (set_cookie ~headers:[ ("host", "localhost:8443") ] ());
  check_header "loopback lookalike"
    (Some "k=v; Path=/in; HttpOnly; Secure; SameSite=Lax; Max-Age=60")
    (set_cookie ~headers:[ ("host", "localhost.example.com") ] ());
  check_header "a TLS proxy says so"
    (Some "k=v; Path=/in; HttpOnly; Secure; SameSite=Lax; Max-Age=60")
    (set_cookie ~proxied:true
       ~headers:[ ("host", "localhost"); ("x-forwarded-proto", "https") ]
       ());
  check_header "and a client saying so is not a proxy"
    (Some "k=v; Path=/in; HttpOnly; SameSite=Lax; Max-Age=60")
    (set_cookie
       ~headers:[ ("host", "localhost"); ("x-forwarded-proto", "https") ]
       ())

(* A value is a constant or it is encoded: an invalid constant is a bug, and
   says so without saying the value, which may be a credential. A name is
   refused where the cookie is declared, and a value where it is made. *)
let test_a_cookie_refuses_what_it_cannot_hold () =
  List.iter
    (fun (name, value) ->
      match
        Spindle.Cookie.make
          (Spindle.Cookie.named name Spindle.Codec.string)
          value
      with
      | _ -> Alcotest.failf "%S=%S was made" name value
      | exception Invalid_argument m ->
          Alcotest.(check bool)
            "the message keeps the value to itself" false
            (String.length value > 3 && contains ~sub:value m))
    [
      ("k", "a;b");
      ("k", "a b");
      ("k", "secret\r\nSet-Cookie: x=1");
      ("a b", "v");
      ("", "v");
      ("k", "back\\slash");
    ];
  ignore
    (Spindle.Cookie.make
       (Spindle.Cookie.named "k" Spindle.Codec.string)
       "\"quoted\""
      : Spindle.Cookie.t);
  ignore
    (Spindle.Cookie.clear (Spindle.Cookie.named "k" Spindle.Codec.string)
      : Spindle.Cookie.t)

(* The Set-Cookie line a route writes for [cookie]. *)
let written cookie =
  let app =
    Spindle.Test.app
      [
        Spindle.post Spindle.Path.root Spindle.Returns.text
          (let+ set_cookie = Spindle.set_cookie in
           set_cookie cookie;
           Ok "set");
      ]
  in
  Option.value ~default:""
    (Spindle.Test.header (Spindle.Test.call app `POST "/") "set-cookie")

let decoded =
  Spindle.get
    Spindle.Path.(s "decoded")
    Spindle.Returns.response
    (let+ v =
       Spindle.Cookie.optional (Spindle.Cookie.named "k" Spindle.Cookie.encoded)
     in
     Ok (Spindle.Response.make (Option.value v ~default:"<none>")))

let test_an_encoded_cookie_carries_any_text =
  QCheck.Test.make ~count:300 ~name:"an encoded cookie carries any text"
    QCheck.string (fun v ->
      let c =
        Spindle.Cookie.make (Spindle.Cookie.named "k" Spindle.Cookie.encoded) v
      in
      let sent =
        match String.split_on_char ';' (written c) with
        | pair :: _ -> pair
        | [] -> ""
      in
      let r =
        Spindle.Test.call
          (Spindle.Test.app [ decoded ])
          `GET "/decoded"
          ~headers:[ ("cookie", sent) ]
      in
      String.equal r.body v)

(* A cookie the server did not write is an input that does not parse, and
   the request is told so; one that is not there at all is none. *)
let test_a_cookie_not_encoded_by_us_is_a_problem () =
  List.iter
    (fun sent ->
      let r =
        Spindle.Test.call
          (Spindle.Test.app [ decoded ])
          `GET "/decoded"
          ~headers:[ ("cookie", sent) ]
      in
      check_status sent 400 r.status;
      Alcotest.(check bool)
        "at the cookie" true
        (contains ~sub:"cookie.k" r.body))
    [ "k=not*base64"; "k=a" ];
  check_string "none" "<none>"
    (Spindle.Test.call
       (Spindle.Test.app [ decoded ])
       `GET "/decoded"
       ~headers:[ ("cookie", "other=aGk") ])
      .body

(* ---------------------------------------------------------------- *)
(* Cookies a browser cannot forge *)

let key secret =
  match Spindle.Key.of_secret secret with
  | Ok k -> k
  | Error m -> Alcotest.fail m

let old_key = key (String.make 32 'o')
and new_key = key (String.make 32 'n')

(* A route that sets the cookie, and one that reads it, both through the
   same declaration. *)
let sealed_app c =
  Spindle.Test.app
    [
      Spindle.post
        Spindle.Path.(s "set" / Spindle.Path.str "v")
        Spindle.Returns.text
        (let+ v = Spindle.param (Spindle.Path.str "v")
         and+ set_cookie = Spindle.set_cookie in
         set_cookie (Spindle.Cookie.make c v);
         Ok "set");
      Spindle.get
        Spindle.Path.(s "read")
        Spindle.Returns.text
        (let+ v = Spindle.Cookie.optional c in
         Ok (Option.value v ~default:"absent"));
    ]

let issued ?(now = 0) app v =
  let r = Spindle.Test.call ~now app `POST ("/set/" ^ v) in
  match Spindle.Test.header r "set-cookie" with
  | Some h -> (
      match String.index_opt h ';' with Some i -> String.sub h 0 i | None -> h)
  | None -> Alcotest.fail "no cookie was set"

(* The Set-Cookie an answer carries for [cookie], as the server writes it. *)
let read_with ?(now = 0) app cookie =
  (Spindle.Test.call ~now app `GET "/read" ~headers:[ ("cookie", cookie) ]).body

let value_of cookie =
  match String.index_opt cookie '=' with
  | Some i -> String.sub cookie (i + 1) (String.length cookie - i - 1)
  | None -> ""

let test_a_key_is_made_from_a_secret () =
  Alcotest.(check bool)
    "one shorter than 32 bytes is refused, in a sentence" true
    (match Spindle.Key.of_secret "short" with
    | Error m -> Char.equal m.[String.length m - 1] '.'
    | Ok _ -> false);
  let ring = Spindle.Key.ring new_key [ old_key ] in
  let mac = Spindle.Key.sign ring "text" in
  Alcotest.(check bool)
    "a mac verifies" true
    (Spindle.Key.verify ring ~mac "text");
  Alcotest.(check bool)
    "and not for other text" false
    (Spindle.Key.verify ring ~mac "texT");
  Alcotest.(check bool)
    "nor a mac of another length" false
    (Spindle.Key.verify ring ~mac:"short" "text");
  let sealed = Spindle.Key.seal ring ~adata:"a" "secret" in
  Alcotest.(check (option string))
    "a seal opens" (Some "secret")
    (Spindle.Key.unseal ring ~adata:"a" sealed);
  Alcotest.(check (option string))
    "under its own adata only" None
    (Spindle.Key.unseal ring ~adata:"b" sealed);
  Alcotest.(check bool)
    "and a nonce is never used twice" false
    (String.equal sealed (Spindle.Key.seal ring ~adata:"a" "secret"))

let test_a_sealed_cookie_reads_only_as_it_was_made make =
  let ring = Spindle.Key.ring new_key [] in
  let c = make ring "prefs" in
  let app = sealed_app c in
  let cookie = issued app "dark" in
  check_string "it reads back" "dark" (read_with app cookie);
  let v = value_of cookie in
  let edited =
    String.mapi
      (fun i ch ->
        if i = String.length v - 3 then if Char.equal ch 'A' then 'B' else 'A'
        else ch)
      v
  in
  check_string "a value a browser edited is absent" "absent"
    (read_with app ("prefs=" ^ edited));
  let elsewhere = sealed_app (make ring "other") in
  check_string "one moved from another cookie is absent" "absent"
    (read_with app ("prefs=" ^ value_of (issued elsewhere "dark")));
  let later = sealed_app (make (Spindle.Key.ring old_key []) "prefs") in
  check_string "one sealed under a key the ring does not hold is absent"
    "absent" (read_with later cookie);
  let rotated =
    sealed_app (make (Spindle.Key.ring old_key [ new_key ]) "prefs")
  in
  check_string "one sealed under a retired key still reads" "dark"
    (read_with rotated cookie)

let test_a_signed_cookie_reads_only_as_it_was_made () =
  test_a_sealed_cookie_reads_only_as_it_was_made (fun ring name ->
      Spindle.Cookie.signed ring name Spindle.Codec.string)

let test_an_encrypted_cookie_reads_only_as_it_was_made () =
  test_a_sealed_cookie_reads_only_as_it_was_made (fun ring name ->
      Spindle.Cookie.encrypted ring name Spindle.Codec.string);
  let c =
    Spindle.Cookie.encrypted
      (Spindle.Key.ring new_key [])
      "prefs" Spindle.Codec.string
  in
  Alcotest.(check bool)
    "and nothing of its value is on the wire" false
    (contains ~sub:"dark" (issued (sealed_app c) "dark"))

let test_a_sealed_cookie_ages () =
  let ring = Spindle.Key.ring new_key [] in
  let c = Spindle.Cookie.signed ring ~max_age:60 "who" Spindle.Codec.string in
  let app = sealed_app c in
  let made = 1_000_000 in
  let cookie = issued ~now:made app "kim" in
  check_string "within its age" "kim"
    (read_with ~now:(made + 59_000) app cookie);
  check_string "past it, absent, whatever the browser was told" "absent"
    (read_with ~now:(made + 61_000) app cookie);
  let header =
    Option.value ~default:""
      (Spindle.Test.header (Spindle.Test.call app `POST "/set/x") "set-cookie")
  in
  Alcotest.(check bool)
    "its age is its Max-Age" true
    (contains ~sub:"Max-Age=60" header);
  let shorter = written (Spindle.Cookie.make ~max_age:30 c "x")
  and longer = written (Spindle.Cookie.make ~max_age:600 c "x") in
  Alcotest.(check bool)
    "a make may shorten it" true
    (contains ~sub:"Max-Age=30" shorter);
  Alcotest.(check bool)
    "and never lengthen it" true
    (contains ~sub:"Max-Age=60" longer);
  let required =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(s "who")
          Spindle.Returns.text
          (let+ v = Spindle.Cookie.required c in
           Ok v);
      ]
  in
  check_status "a required one that does not open is a problem" 400
    (Spindle.Test.call required `GET "/who"
       ~headers:[ ("cookie", "who=forged") ])
      .status

(* ---------------------------------------------------------------- *)
(* Sessions *)

(* The memory store, recording every key it was given and every save. *)
let recorded () =
  let store = Spindle.Session.memory () and keys = ref [] and saves = ref 0 in
  ( {
      store with
      Spindle.Session.save =
        (fun digest e ->
          keys := digest :: !keys;
          incr saves;
          store.save digest e);
    },
    keys,
    saves )

let session_routes sessions =
  let v = Spindle.Path.str "v" in
  let me = Spindle.Session.cookie sessions in
  let found f =
    let+ session = me
    and+ set_cookie = Spindle.set_cookie
    and+ now = Spindle.now
    and+ value = Spindle.Dep.return () in
    ignore value;
    match Spindle.Session.find sessions session ~now with
    | Error e -> Error (Spindle.Session.refusal e)
    | Ok s -> f s ~set_cookie ~now
  in
  let answered = function
    | Ok s -> Ok (Spindle.Session.data s)
    | Error e -> Error (Spindle.Session.refusal e)
  in
  Spindle.Test.app
    [
      Spindle.post
        Spindle.Path.(s "start" / v)
        Spindle.Returns.text
        (let+ v = Spindle.param v
         and+ set_cookie = Spindle.set_cookie
         and+ now = Spindle.now in
         answered (Spindle.Session.start sessions ~set_cookie ~now v));
      Spindle.get
        Spindle.Path.(s "me")
        Spindle.Returns.text
        (found (fun s ~set_cookie:_ ~now:_ ->
             Ok
               (match s with
               | Some s -> Spindle.Session.data s
               | None -> "nobody")));
      Spindle.post
        Spindle.Path.(s "renew" / v)
        Spindle.Returns.text
        (Spindle.Dep.bind (Spindle.param v) (fun v ->
             found (fun s ~set_cookie ~now ->
                 match s with
                 | Some s ->
                     answered
                       (Spindle.Session.renew sessions s ~set_cookie ~now v)
                 | None -> Ok "nobody")));
      Spindle.post
        Spindle.Path.(s "update" / v)
        Spindle.Returns.text
        (Spindle.Dep.bind (Spindle.param v) (fun v ->
             found (fun s ~set_cookie:_ ~now ->
                 match s with
                 | Some s -> answered (Spindle.Session.update sessions s ~now v)
                 | None -> Ok "nobody")));
      Spindle.post
        Spindle.Path.(s "close")
        Spindle.Returns.text
        (found (fun s ~set_cookie ~now:_ ->
             match s with
             | Some s ->
                 Result.map
                   (fun () -> "closed")
                   (Result.map_error Spindle.Session.refusal
                      (Spindle.Session.close sessions s ~set_cookie))
             | None -> Ok "nobody"));
    ]

let session_cookie (r : Spindle.Test.response) =
  match Spindle.Test.header r "set-cookie" with
  | Some h -> (
      match String.index_opt h ';' with Some i -> String.sub h 0 i | None -> h)
  | None -> Alcotest.fail "no session cookie"

let as_visitor ?(now = 0) app cookie meth target =
  Spindle.Test.call ~now app meth target ~headers:[ ("cookie", cookie) ]

let test_a_session_is_kept_on_the_server () =
  let store, keys, _ = recorded () in
  let sessions =
    Spindle.Session.create ~store ~idle_s:3600 ~absolute_s:86400 Wiretype.string
  in
  let app = session_routes sessions in
  let started = Spindle.Test.call app `POST "/start/kim" in
  let header =
    Option.value ~default:"" (Spindle.Test.header started "set-cookie")
  in
  Alcotest.(check bool)
    "its cookie is HttpOnly, SameSite=Lax, and lasts its absolute limit" true
    (contains ~sub:"HttpOnly" header
    && contains ~sub:"SameSite=Lax" header
    && contains ~sub:"Max-Age=86400" header);
  let cookie = session_cookie started in
  let id = String.sub cookie 8 (String.length cookie - 8) in
  check_string "the session is found by its cookie" "kim"
    (as_visitor app cookie `GET "/me").body;
  Alcotest.(check bool)
    "and the store holds its digest, never its id" true
    (List.for_all
       (fun k -> String.length k = 64 && not (String.equal k id))
       !keys);
  check_string "an update keeps the id" "kim+"
    (as_visitor app cookie `POST "/update/kim+").body;
  check_string "and is found under it" "kim+"
    (as_visitor app cookie `GET "/me").body;
  let renewed = as_visitor app cookie `POST "/renew/kim-signed-in" in
  let fresh = session_cookie renewed in
  Alcotest.(check bool)
    "a renewal is a new id" false
    (String.equal fresh cookie);
  check_string "the old id signs nobody in" "nobody"
    (as_visitor app cookie `GET "/me").body;
  check_string "the new one does" "kim-signed-in"
    (as_visitor app fresh `GET "/me").body;
  let closed = as_visitor app fresh `POST "/close" in
  Alcotest.(check bool)
    "closing clears the cookie" true
    (contains ~sub:"Max-Age=0"
       (Option.value ~default:"" (Spindle.Test.header closed "set-cookie")));
  check_string "and a copy of it signs nobody in" "nobody"
    (as_visitor app fresh `GET "/me").body;
  check_string "nor does an id nobody made" "nobody"
    (as_visitor app "session=AAAAAAAAAAAAAAAAAAAAAA" `GET "/me").body

let test_a_session_ends_by_its_limits () =
  let store, _, saves = recorded () in
  let sessions =
    Spindle.Session.create ~store ~idle_s:100 ~absolute_s:250 Wiretype.string
  in
  let app = session_routes sessions in
  let cookie = session_cookie (Spindle.Test.call app `POST "/start/kim") in
  let me now = (as_visitor ~now app cookie `GET "/me").body in
  let before = !saves in
  check_string "within its idle limit" "kim" (me 5_000);
  check_int "and not written for it" before !saves;
  check_string "found past a tenth of it" "kim" (me 50_000);
  check_int "and moved on" (before + 1) !saves;
  check_string "idle from there" "kim" (me 140_000);
  check_string "and again" "kim" (me 230_000);
  check_string "past its absolute limit, however busy" "nobody" (me 260_000);
  let other = session_cookie (Spindle.Test.call app `POST "/start/lee") in
  check_string "and one left alone past its idle limit" "nobody"
    (as_visitor ~now:101_000 app other `GET "/me").body;
  let old = session_cookie (Spindle.Test.call ~now:0 app `POST "/start/old") in
  ignore old;
  (match Spindle.Session.sweep sessions ~now:1_000_000 with
  | Ok n ->
      Alcotest.(check bool) "a sweep deletes what has expired" true (n >= 1)
  | Error _ -> Alcotest.fail "the sweep failed");
  let ints =
    Spindle.Session.create ~store ~idle_s:100 ~absolute_s:250 Wiretype.int
  in
  let cookie = session_cookie (Spindle.Test.call app `POST "/start/text") in
  let reads_ints =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(s "n")
          Spindle.Returns.text
          (let+ session = Spindle.Session.cookie ints and+ now = Spindle.now in
           match Spindle.Session.find ints session ~now with
           | Ok (Some s) -> Ok (string_of_int (Spindle.Session.data s))
           | Ok None -> Ok "nobody"
           | Error e -> Error (Spindle.Session.refusal e));
      ]
  in
  check_string "data that no longer reads is no session" "nobody"
    (as_visitor reads_ints cookie `GET "/n").body

let test_clearing_a_cookie () =
  check_string "no value, no lifetime"
    "session=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0"
    (written
       (Spindle.Cookie.clear
          (Spindle.Cookie.named "session" Spindle.Codec.string)))

(* ------------------------------------------------------------------ *)
(* Forgery *)

let posted =
  Spindle.post
    Spindle.Path.(s "act")
    Spindle.Returns.response
    (Spindle.Dep.return (Ok (Spindle.Response.make "done")))

let act ?(app = Spindle.Test.app [ posted; hello ]) ?proxied ?(meth = `POST)
    ?(path = "/act") headers =
  (Spindle.Test.call app meth path ?proxied ~headers).status

(* The rule, case by case, as Go's CrossOriginProtection has it. *)
let test_a_request_from_another_site_is_refused () =
  let here = ("host", "example.com") in
  check_status "another site's form, by Origin" 403
    (act [ here; ("origin", "https://evil.example") ]);
  check_status "and by Sec-Fetch-Site" 403
    (act [ here; ("sec-fetch-site", "cross-site") ]);
  check_status "a sibling subdomain is another site" 403
    (act [ here; ("sec-fetch-site", "same-site") ]);
  check_status "an opaque origin" 403 (act [ here; ("origin", "null") ]);
  check_status "even one a list names" 403
    (act
       ~app:(Spindle.Test.app ~trusted_origins:[ "null" ] [ posted; hello ])
       [ here; ("origin", "null"); ("sec-fetch-site", "cross-site") ]);
  check_status "this site, by Sec-Fetch-Site" 200
    (act
       [
         here;
         ("sec-fetch-site", "same-origin");
         ("origin", "https://example.com");
       ]);
  check_status "this site, by Origin alone" 200
    (act [ here; ("origin", "https://example.com") ]);
  check_status "this site on the other scheme is its own operator" 200
    (act [ here; ("origin", "http://example.com") ]);
  check_status "this site at an IPv6 address, by Origin alone" 200
    (act [ ("host", "[::1]:8443"); ("origin", "https://[::1]:8443") ]);
  check_status "another port at that address is another site" 403
    (act [ ("host", "[::1]:8443"); ("origin", "https://[::1]:9443") ]);
  check_status "typed into the address bar" 200
    (act [ here; ("sec-fetch-site", "none") ]);
  check_status "no browser at all" 200 (act [ here ]);
  check_status "a GET from anywhere" 200
    (act ~meth:`GET ~path:"/hello/kim"
       [ here; ("sec-fetch-site", "cross-site") ])

let test_a_trusted_origin_and_a_trusted_proxy_pass () =
  let trusting =
    Spindle.Test.app ~trusted_origins:[ "https://app.example" ] [ posted ]
  in
  check_status "a trusted origin" 200
    (act ~app:trusting
       [
         ("host", "api.example");
         ("sec-fetch-site", "same-site");
         ("origin", "https://app.example");
       ]);
  let behind =
    [
      ("host", "10.0.0.5:8080");
      ("x-forwarded-host", "example.com");
      ("origin", "https://example.com");
    ]
  in
  check_status "behind a proxy that rewrites Host" 200
    (act ~proxied:true behind);
  check_status "but a client cannot claim to be one" 403 (act behind);
  let off = Spindle.Test.app ~check_origin:false [ posted ] in
  check_status "and it can be turned off, by name" 200
    (act ~app:off [ ("sec-fetch-site", "cross-site") ])

(* A browser sends text/plain from another site without asking; JSON only
   after a preflight. *)
(* ---------------------------------------------------------------- *)
(* Forms *)

let form_headers = [ ("content-type", "application/x-www-form-urlencoded") ]

let problems_of body =
  match Yojson.Safe.from_string body with
  | `Assoc members -> (
      match List.assoc_opt "problems" members with
      | Some (`List ps) ->
          List.filter_map
            (function
              | `Assoc p -> (
                  match List.assoc_opt "at" p with
                  | Some (`String at) -> Some at
                  | _ -> None)
              | _ -> None)
            ps
      | Some _ | None -> [])
  | _ -> []

let profile =
  Spindle.post
    Spindle.Path.(s "profile")
    Spindle.Returns.text
    (let+ email = Spindle.Form.required "email" Spindle.Codec.string
     and+ age = Spindle.Form.optional "age" Spindle.Codec.int
     and+ tags = Spindle.Form.list "tag" Spindle.Codec.string
     and+ remember = Spindle.Form.checked "remember" in
     Ok
       (Printf.sprintf "%s %s [%s] %b" email
          (match age with Some a -> string_of_int a | None -> "-")
          (String.concat "," tags) remember))

let test_a_form's_fields_are_typed_inputs () =
  let a = Spindle.Test.app [ profile ] in
  let post ?(headers = form_headers) body =
    Spindle.Test.call a `POST "/profile" ~headers ~body
  in
  check_string "each field, typed" "kim@x.io 30 [a,b c] true"
    (post "email=kim%40x.io&age=30&tag=a&tag=b+c&remember=on").body;
  check_string "a box not ticked is not sent" "kim@x.io - [] false"
    (post "email=kim%40x.io").body;
  check_string "a parameter of the type changes nothing" "k - [] false"
    (post
       ~headers:
         [
           ("content-type", "application/x-www-form-urlencoded; charset=utf-8");
         ]
       "email=k")
      .body;
  let wrong = post "age=old&tag=%FF" in
  check_status "a wrong form" 400 wrong.status;
  Alcotest.(check (list string))
    "names every wrong field at once"
    [ "form.email"; "form.age"; "form.tag" ]
    (problems_of wrong.body)

let test_a_form_is_read_once_and_only_as_a_form () =
  let read = ref 0 and ran = ref 0 in
  let a = Spindle.Test.app [ profile ] in
  let call headers body =
    fst
      (Spindle.App.handle a
         (Spindle.Request.make ~headers ~now:(fun () -> 0) `POST "/profile")
         ~body:
           {
             Spindle.Body.whole =
               (fun () ->
                 incr read;
                 Ok body);
             part = (fun ~max:_ -> Ok `End);
           })
  in
  check_status "four fields" 200
    (Spindle.Status.to_int
       (Spindle.Response.status (call form_headers "email=a&age=1&tag=x")));
  check_int "one read of the body" 1 !read;
  check_status "another type is 415" 415
    (Spindle.Status.to_int
       (Spindle.Response.status
          (call [ ("content-type", "application/json") ] {|{"email":"a"}|})));
  check_int "before the body is read" 1 !read;
  check_status "and no type at all is read as a form" 200
    (Spindle.Status.to_int
       (Spindle.Response.status (call [] "email=a&age=1&tag=x")));
  let counted =
    Spindle.post
      Spindle.Path.(s "count")
      Spindle.Returns.text
      (let+ _ = Spindle.Form.optional "a" Spindle.Codec.string in
       incr ran;
       Ok "ran")
  in
  let forged =
    Spindle.Test.call
      (Spindle.Test.app [ counted ])
      `POST "/count"
      ~headers:
        (("sec-fetch-site", "cross-site")
        :: ("origin", "https://evil.example")
        :: form_headers)
      ~body:"a=1"
  in
  check_status "a form from another site" 403 forged.status;
  check_int "is refused before the route runs" 0 !ran;
  let beside body =
    Spindle.App.make
      [
        Spindle.post
          Spindle.Path.(s "x")
          Spindle.Returns.text
          (let+ _ = Spindle.Form.optional "a" Spindle.Codec.string
           and+ _ = body in
           Ok "");
      ]
  in
  Alcotest.(check bool)
    "a form beside JSON is refused when the app is made" true
    (Result.is_error
       (beside (Spindle.json greeting_json |> Spindle.Dep.map ignore)));
  Alcotest.(check bool)
    "and beside a stream" true
    (Result.is_error
       (beside (Spindle.body_stream ~max:10 () |> Spindle.Dep.map ignore)));
  Alcotest.(check bool)
    "and two fields are one body" true
    (Result.is_ok
       (beside
          (Spindle.Form.required "b" Spindle.Codec.int |> Spindle.Dep.map ignore)))

let test_a_form_is_described () =
  match Spindle.Openapi.document (Spindle.Test.app [ profile ]) with
  | Error _ -> Alcotest.fail "no document"
  | Ok doc ->
      let open Yojson.Safe.Util in
      let schema =
        Yojson.Safe.from_string doc
        |> member "paths" |> member "/profile" |> member "post"
        |> member "requestBody" |> member "content"
        |> member "application/x-www-form-urlencoded"
        |> member "schema"
      in
      Alcotest.(check (list string))
        "as a form, each field"
        [ "email"; "age"; "tag"; "remember" ]
        (keys (member "properties" schema));
      Alcotest.(check string)
        "typed by its codec" "integer"
        (schema |> member "properties" |> member "age" |> member "type"
       |> to_string);
      Alcotest.(check string)
        "a repeated one a list" "array"
        (schema |> member "properties" |> member "tag" |> member "type"
       |> to_string);
      Alcotest.(check (list string))
        "and the required ones said" [ "email" ]
        (List.map to_string (to_list (member "required" schema)))

(* A multipart body, as a browser writes one, for the cases below. *)
let multipart_body parts =
  let module M = Spindle_http.Multipart in
  let media t =
    match
      Spindle_http.Media_type.parse (Option.value t ~default:"text/plain")
    with
    | Ok m -> m
    | Error e -> Alcotest.fail e
  in
  M.to_string ~boundary:"XyZ"
    (List.map
       (fun (name, filename, content_type, content) ->
         ( { M.name; filename; content_type = media content_type; headers = [] },
           content ))
       parts)

let multipart_headers =
  [ ("content-type", {|multipart/form-data; boundary="XyZ"|}) ]

let uploads =
  let rec each parts acc =
    match Spindle.Multipart.next parts with
    | Ok None -> Ok (String.concat ";" (List.rev acc))
    | Ok (Some (part : Spindle.Multipart.part))
      when String.equal part.name "skip" ->
        each parts acc
    | Ok (Some part) -> (
        let b = Buffer.create 16 in
        let rec read () =
          match Spindle.Multipart.read parts with
          | Ok (`Data d) ->
              Buffer.add_string b d;
              read ()
          | Ok `End -> Ok (Buffer.contents b)
          | Error e -> Error e
        in
        match read () with
        | Ok c ->
            each parts
              ((part.name ^ "="
               ^ Option.value part.filename ~default:""
               ^ ":" ^ c)
              :: acc)
        | Error e -> Error (Spindle.Multipart.refusal e))
    | Error e -> Error (Spindle.Multipart.refusal e)
  in
  Spindle.post
    Spindle.Path.(s "uploads")
    Spindle.Returns.text
    (let+ parts = Spindle.multipart ~max:400 () in
     each parts [])

let test_an_upload_is_read_a_part_at_a_time () =
  let a = Spindle.Test.app [ uploads ] in
  let post ?(headers = multipart_headers) body =
    Spindle.Test.call a `POST "/uploads" ~headers ~body
  in
  check_string "each part, as it arrives, a part left unread passed over"
    "a=:one;f=v.mp4:BYTES"
    (post
       (multipart_body
          [
            ("a", None, None, "one");
            ("skip", None, None, "not read");
            ("f", Some "v.mp4", Some "video/mp4", "BYTES");
          ]))
      .body;
  check_status "past the route's own limit" 413
    (post (multipart_body [ ("f", Some "big", None, String.make 500 'x') ]))
      .status;
  check_status "a body that is no multipart form" 415
    (post ~headers:form_headers "a=1").status;
  let no_boundary =
    post ~headers:[ ("content-type", "multipart/form-data") ] "x"
  in
  check_status "one that names no boundary" 400 no_boundary.status;
  Alcotest.(check (list string))
    "said at the header" [ "header.content-type" ]
    (problems_of no_boundary.body);
  let broken =
    post "--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx"
  in
  check_status "a body that ends before its last boundary" 400 broken.status;
  Alcotest.(check (list string))
    "is malformed" [ "body" ] (problems_of broken.body)

let test_a_form's_files_are_inputs () =
  let avatar = Spindle.Form.file_opt "avatar"
  and docs = Spindle.Form.files "doc"
  and name = Spindle.Form.required "name" Spindle.Codec.string in
  let route =
    Spindle.post
      Spindle.Path.(s "profile")
      Spindle.Returns.text
      (let+ n = name and+ a = avatar and+ d = docs in
       let show (f : Spindle.Form.file) =
         Option.value f.filename ~default:"?"
         ^ "("
         ^ Result.value ~default:"?"
             (Spindle_http.Media_type.to_string f.content_type)
         ^ ")=" ^ f.content
       in
       Ok
         (Printf.sprintf "%s %s [%s]" n
            (match a with Some f -> show f | None -> "-")
            (String.concat "," (List.map show d))))
  in
  let a = Spindle.Test.app [ route ] in
  let post body =
    (Spindle.Test.call a `POST "/profile" ~headers:multipart_headers ~body).body
  in
  check_string "fields and files, from one multipart form"
    "kim me.png(image/png)=PNG [a.txt(text/plain)=A,b.csv(text/csv)=B]"
    (post
       (multipart_body
          [
            ("name", None, None, "kim");
            ("avatar", Some "me.png", Some "image/png", "PNG");
            ("doc", Some "a.txt", None, "A");
            ("doc", Some "b.csv", Some "text/csv", "B");
          ]));
  check_string "a file input left empty is no file" "kim - []"
    (post
       (multipart_body
          [
            ("name", None, None, "kim");
            ("avatar", Some "", Some "application/octet-stream", "");
          ]));
  check_string "and the same fields read from a urlencoded form" "kim - []"
    (Spindle.Test.call a `POST "/profile" ~headers:form_headers ~body:"name=kim")
      .body;
  Alcotest.(check bool)
    "parts beside a form are refused when the app is made" true
    (Result.is_error
       (Spindle.App.make
          [
            Spindle.post
              Spindle.Path.(s "x")
              Spindle.Returns.text
              (let+ _ = name and+ _ = Spindle.multipart ~max:10 () in
               Ok "");
          ]));
  match Spindle.Openapi.document a with
  | Error _ -> Alcotest.fail "no document"
  | Ok doc ->
      let open Yojson.Safe.Util in
      let content =
        Yojson.Safe.from_string doc
        |> member "paths" |> member "/profile" |> member "post"
        |> member "requestBody" |> member "content"
      in
      Alcotest.(check (list string))
        "a form with a file is multipart alone" [ "multipart/form-data" ]
        (keys content);
      Alcotest.(check string)
        "each file a part of its own type" "application/octet-stream"
        (content
        |> member "multipart/form-data"
        |> member "encoding" |> member "avatar" |> member "contentType"
        |> to_string)

let test_urlencoded_reads_as_a_browser_writes () =
  let module U = Spindle_http.Urlencoded in
  Alcotest.(check (list (pair string string)))
    "a plus is a space, a percent its byte, a bare name empty"
    [ ("a b", "c&d"); ("e", ""); ("f", "%zz") ]
    (U.parse "a+b=c%26d&&e&f=%zz");
  let fields = [ ("naïve name", "1 + 1 = 2 & more") ] in
  Alcotest.(check (list (pair string string)))
    "what it writes it reads back" fields
    (U.parse (U.to_string fields))

(* ---------------------------------------------------------------- *)
(* CORS *)

let app_origin = "https://app.example.com"

let cors_routes =
  let say words = Spindle.Dep.return (Ok words) in
  [
    Spindle.get
      Spindle.Path.(s "api" / s "item")
      Spindle.Returns.text (say "item");
    Spindle.post
      Spindle.Path.(s "api" / s "item")
      Spindle.Returns.text (say "posted");
    Spindle.route `OPTIONS
      Spindle.Path.(s "api" / s "item")
      Spindle.Returns.text
      (say "the route's own OPTIONS");
    Spindle.post Spindle.Path.(s "page") Spindle.Returns.text (say "page");
  ]

let api_only (i : Spindle.Route.info) =
  String.starts_with ~prefix:"/api/" i.pattern

let cross_site origin = [ ("sec-fetch-site", "cross-site"); ("origin", origin) ]

let test_a_preflight_is_the_framework's () =
  let a =
    Spindle.Test.app
      ~cors:
        (Spindle.Cors.make ~credentials:true ~routes:api_only
           (Spindle.Cors.Origins [ app_origin ]))
      cors_routes
  in
  let preflight ?(origin = app_origin) target =
    Spindle.Test.call a `OPTIONS target
      ~headers:
        [
          ("origin", origin);
          ("access-control-request-method", "POST");
          ("access-control-request-headers", "Content-Type, X-Unlisted");
        ]
  in
  let r = preflight "/api/item" in
  check_status "answered by the framework" 204 r.status;
  check_header "for the origin itself" (Some app_origin)
    (Spindle.Test.header r "access-control-allow-origin");
  check_header "with the methods the path has" (Some "GET, POST, OPTIONS, HEAD")
    (Spindle.Test.header r "access-control-allow-methods");
  check_header "and the headers asked for that the policy allows"
    (Some "content-type")
    (Spindle.Test.header r "access-control-allow-headers");
  check_header "credentials" (Some "true")
    (Spindle.Test.header r "access-control-allow-credentials");
  check_header "kept for its max age" (Some "600")
    (Spindle.Test.header r "access-control-max-age");
  let other = preflight ~origin:"https://evil.example" "/api/item" in
  check_status "another origin is answered" 204 other.status;
  check_header "and told nothing" None
    (Spindle.Test.header other "access-control-allow-origin");
  check_string "an OPTIONS that is no preflight reaches the route"
    "the route's own OPTIONS"
    (Spindle.Test.call a `OPTIONS "/api/item"
       ~headers:[ ("origin", app_origin) ])
      .body;
  check_status "a route the policy does not cover has no preflight" 405
    (preflight "/page").status

let test_an_answer_says_who_may_read_it () =
  let a =
    Spindle.Test.app
      ~cors:
        (Spindle.Cors.make ~credentials:true ~routes:api_only
           (Spindle.Cors.Origins [ app_origin ]))
      ~middleware:
        [
          (fun h r ->
            if Option.is_some (Spindle.Request.header r "x-deny") then
              Spindle.Response.refusal
                (Spindle.Refusal.make (code "nope" `Forbidden) "No.")
            else h r);
        ]
      ~codes:[ code "nope" `Forbidden ]
      cors_routes
  in
  let get headers = Spindle.Test.call a `GET "/api/item" ~headers in
  let allowed = get [ ("origin", app_origin) ] in
  check_header "an allowed origin may read it" (Some app_origin)
    (Spindle.Test.header allowed "access-control-allow-origin");
  check_header "and it varies by origin" (Some "Origin")
    (Spindle.Test.header allowed "vary");
  let other = get [ ("origin", "https://evil.example") ] in
  check_header "another may not" None
    (Spindle.Test.header other "access-control-allow-origin");
  check_header "and it varies all the same" (Some "Origin")
    (Spindle.Test.header other "vary");
  check_header "a refusal a middleware made is readable too" (Some app_origin)
    (Spindle.Test.header
       (get [ ("origin", app_origin); ("x-deny", "1") ])
       "access-control-allow-origin");
  check_header "and a route it does not cover says nothing" None
    (Spindle.Test.header
       (Spindle.Test.call a `POST "/page" ~headers:[ ("origin", app_origin) ])
       "vary")

let test_an_allowed_origin_may_write () =
  let named =
    Spindle.Test.app
      ~cors:
        (Spindle.Cors.make ~credentials:true ~routes:api_only
           (Spindle.Cors.Origins [ app_origin ]))
      cors_routes
  in
  check_status "a named origin's credentialed write passes the origin check" 200
    (Spindle.Test.call named `POST "/api/item"
       ~headers:(("cookie", "session=s") :: cross_site app_origin))
      .status;
  check_status "another's is still forgery" 403
    (Spindle.Test.call named `POST "/api/item"
       ~headers:(cross_site "https://evil.example"))
      .status;
  check_status "and so is one to a route the policy does not cover" 403
    (Spindle.Test.call named `POST "/page" ~headers:(cross_site app_origin))
      .status;
  let any =
    Spindle.Test.app ~cors:(Spindle.Cors.make Spindle.Cors.Any) cors_routes
  in
  let from_anywhere = cross_site "https://anyone.example" in
  let r = Spindle.Test.call any `POST "/api/item" ~headers:from_anywhere in
  check_status "under Any, a write with no cookie passes" 200 r.status;
  check_header "readable by anyone" (Some "*")
    (Spindle.Test.header r "access-control-allow-origin");
  check_status "and one riding a cookie is forgery still" 403
    (Spindle.Test.call any `POST "/api/item"
       ~headers:(("cookie", "session=s") :: from_anywhere))
      .status;
  Alcotest.(check bool)
    "Any beside credentials is refused" true
    (match Spindle.Cors.make ~credentials:true Spindle.Cors.Any with
    | _ -> false
    | exception Invalid_argument _ -> true)

(* ---------------------------------------------------------------- *)
(* Compression *)

let gunzip = Test_gz.gunzip

let large =
  String.concat "," (List.init 300 (fun i -> Printf.sprintf {|{"n":%d}|} i))

let compressed_routes =
  let say ?meta ?(headers = []) path content_type body =
    Spindle.get ?meta
      Spindle.Path.(s path)
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok (Spindle.Response.make ~headers ~content_type body)))
  in
  [
    say "large" "application/json"
      ("[" ^ large ^ "]")
      ~headers:[ ("etag", {|"v1"|}) ];
    say "small" "application/json" "[1]";
    say "image" "image/png" (String.make 4096 'x');
    say "secret" "application/json" (String.make 4096 'x')
      ~meta:Spindle.Meta.(empty |> add Spindle.Compress.never ());
    say "kept" "application/json" (String.make 4096 'x')
      ~headers:[ ("cache-control", "no-transform") ];
  ]

let test_a_stream_compresses_in_process () =
  let events =
    Spindle.get
      Spindle.Path.(s "ticks")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.events (fun send ->
                 let ( let* ) = Result.bind in
                 let* () = send "data: one\n\n" in
                 send "data: two\n\n"))))
  in
  let a = Spindle.Test.app ~compress:Spindle.Compress.default [ events ] in
  let r =
    Spindle.Test.call a `GET "/ticks" ~headers:[ ("accept-encoding", "gzip") ]
  in
  check_string "a stream reads back whole" "data: one\n\ndata: two\n\n"
    (gunzip r.body)

let test_an_answer_is_compressed_where_it_may_be () =
  let a =
    Spindle.Test.app ~compress:Spindle.Compress.default compressed_routes
  in
  let get ?(accept = "gzip, br") ?(meth = `GET) path =
    Spindle.Test.call a meth path ~headers:[ ("accept-encoding", accept) ]
  in
  let r = get "/large" in
  check_header "gzip, where the client takes it" (Some "gzip")
    (Spindle.Test.header r "content-encoding");
  check_header "varying by the coding" (Some "Accept-Encoding")
    (Spindle.Test.header r "vary");
  check_string "and it reads back as it was" ("[" ^ large ^ "]") (gunzip r.body);
  Alcotest.(check bool)
    "smaller" true
    (String.length r.body < String.length large / 2);
  check_header "its tag names its coding" (Some {|"v1-gzip"|})
    (Spindle.Test.header r "etag");
  check_header "a HEAD says the length its GET would"
    (Spindle.Test.header r "content-length")
    (Spindle.Test.header (get ~meth:`HEAD "/large") "content-length");
  check_header "a coding taken on a later line is taken all the same"
    (Some "gzip")
    (Spindle.Test.header
       (Spindle.Test.call a `GET "/large"
          ~headers:[ ("accept-encoding", "br"); ("accept-encoding", "gzip") ])
       "content-encoding");
  let plain = get ~accept:"identity" "/large" in
  check_header "not where it does not" None
    (Spindle.Test.header plain "content-encoding");
  check_header "and varying all the same" (Some "Accept-Encoding")
    (Spindle.Test.header plain "vary");
  check_header "nor where gzip is refused by weight" None
    (Spindle.Test.header
       (get ~accept:"gzip;q=0, *" "/large")
       "content-encoding");
  List.iter
    (fun (path, why) ->
      check_header why None (Spindle.Test.header (get path) "content-encoding"))
    [
      ("/small", "nor a body too small to be worth it");
      ("/image", "nor a type that is not listed");
      ("/secret", "nor a route that said never");
      ("/kept", "nor an answer that says no-transform");
    ];
  check_header "a type not listed does not vary" None
    (Spindle.Test.header (get "/image") "vary");
  let off = Spindle.Test.app compressed_routes in
  check_header "and nothing is compressed unless the app says" None
    (Spindle.Test.header
       (Spindle.Test.call off `GET "/large"
          ~headers:[ ("accept-encoding", "gzip") ])
       "content-encoding")

(* ---------------------------------------------------------------- *)
(* Rate limits *)

(* A burst is how many calls pass at once, and the rate how soon the next
   one does after that: two a second with a burst of five lets five through,
   then one every half second. *)
let test_a_burst_is_its_own_figure () =
  let mono_clock = Eio_mock.Clock.Mono.make () in
  let calls = Spindle.Rate.create ~mono_clock ~limit:2 ~per_s:1. ~burst:5 () in
  let a =
    Spindle.Test.app
      [
        Spindle.post
          Spindle.Path.(s "call")
          Spindle.Returns.text
          (let+ () = Spindle.Rate.limit calls ~key:Spindle.client in
           Ok "in");
      ]
  in
  let call () = (Spindle.Test.call a `POST "/call").status in
  for i = 1 to 5 do
    check_status (Printf.sprintf "call %d, within its burst" i) 200 (call ())
  done;
  check_status "the sixth at once" 429 (call ());
  Eio_mock.Clock.Mono.set_time mono_clock (Mtime.of_uint64_ns 400_000_000L);
  check_status "not yet at 0.4s" 429 (call ());
  Eio_mock.Clock.Mono.set_time mono_clock (Mtime.of_uint64_ns 500_000_000L);
  check_status "one at half a second" 200 (call ());
  check_status "and only one" 429 (call ())

let test_a_limit_refuses_past_its_rate () =
  let mono_clock = Eio_mock.Clock.Mono.make () in
  let sign_ins = Spindle.Rate.create ~mono_clock ~limit:10 ~per_s:1. () in
  let route =
    Spindle.post
      Spindle.Path.(s "sign-in")
      Spindle.Returns.text
      (let+ () = Spindle.Rate.limit sign_ins ~key:Spindle.client in
       Ok "in")
  and open_ =
    Spindle.get
      Spindle.Path.(s "open")
      Spindle.Returns.text
      (Spindle.Dep.return (Ok "open"))
  in
  let a = Spindle.Test.app [ route; open_ ] in
  let call ?(peer = "10.0.0.1") () =
    Spindle.Test.call ~peer a `POST "/sign-in"
  in
  for i = 1 to 10 do
    check_status
      (Printf.sprintf "call %d, within its burst" i)
      200 (call ()).status
  done;
  let refused = call () in
  check_status "the eleventh in a second" 429 refused.status;
  check_header "says when to ask again" (Some "1")
    (Spindle.Test.header refused "retry-after");
  check_status "another key is its own" 200 (call ~peer:"10.0.0.2" ()).status;
  Eio_mock.Clock.Mono.set_time mono_clock (Mtime.of_uint64_ns 100_000_000L);
  check_status "a tenth of a second on, one more" 200 (call ()).status;
  check_status "and only one" 429 (call ()).status;
  match Spindle.Openapi.document a with
  | Error _ -> Alcotest.fail "no document"
  | Ok doc ->
      let open Yojson.Safe.Util in
      let responses path meth =
        keys
          (Yojson.Safe.from_string doc
          |> member "paths" |> member path |> member meth |> member "responses"
          )
      in
      Alcotest.(check bool)
        "the document names the 429 where there is a limit" true
        (List.mem "429" (responses "/sign-in" "post"));
      Alcotest.(check bool)
        "and nowhere else" false
        (List.mem "429" (responses "/open" "get"))

(* ---------------------------------------------------------------- *)
(* Tests that keep cookies and read a stream *)

let test_a_test_browser_keeps_what_the_app_set () =
  let sessions =
    Spindle.Session.create
      ~store:(Spindle.Session.memory ())
      ~idle_s:3600 ~absolute_s:86400 Wiretype.string
  in
  let me = Spindle.Session.cookie sessions in
  let routes =
    [
      Spindle.post
        Spindle.Path.(s "sign-in")
        Spindle.Returns.text
        (let+ set_cookie = Spindle.set_cookie and+ now = Spindle.now in
         Result.map_error Spindle.Session.refusal
           (Result.map
              (fun _ -> "in")
              (Spindle.Session.start sessions ~set_cookie ~now "kim")));
      Spindle.get
        Spindle.Path.(s "me")
        Spindle.Returns.text
        (let+ session = me and+ now = Spindle.now in
         match Spindle.Session.find sessions session ~now with
         | Ok (Some s) -> Ok (Spindle.Session.data s)
         | Ok None -> Ok "nobody"
         | Error e -> Error (Spindle.Session.refusal e));
      Spindle.post
        Spindle.Path.(s "sign-out")
        Spindle.Returns.text
        (let+ session = me
         and+ set_cookie = Spindle.set_cookie
         and+ now = Spindle.now in
         match Spindle.Session.find sessions session ~now with
         | Ok (Some s) ->
             Result.map_error Spindle.Session.refusal
               (Result.map
                  (fun () -> "out")
                  (Spindle.Session.close sessions s ~set_cookie))
         | Ok None -> Ok "nobody"
         | Error e -> Error (Spindle.Session.refusal e));
      Spindle.post
        Spindle.Path.(s "games" / Spindle.Path.str "g")
        Spindle.Returns.text
        (let+ g = Spindle.param (Spindle.Path.str "g")
         and+ set_cookie = Spindle.set_cookie in
         set_cookie
           (Spindle.Cookie.make ~path:("/games/" ^ g) ~max_age:60
              (Spindle.Cookie.named "seat" Spindle.Codec.string)
              g);
         Ok "seated");
      Spindle.get
        Spindle.Path.(s "games" / Spindle.Path.str "g" / s "seat")
        Spindle.Returns.text
        (let+ seat =
           Spindle.Cookie.optional
             (Spindle.Cookie.named "seat" Spindle.Codec.string)
         in
         Ok (Option.value seat ~default:"none"));
    ]
  in
  let b = Spindle.Test.browser (Spindle.Test.app routes) in
  let call ?now meth target =
    (Spindle.Test.Browser.call ?now b meth target).body
  in
  check_string "nobody before signing in" "nobody" (call `GET "/me");
  check_string "signed in" "in" (call `POST "/sign-in");
  check_string "and the next call carries the session" "kim" (call `GET "/me");
  check_string "signed out" "out" (call `POST "/sign-out");
  check_string "and the cookie is gone with it" "nobody" (call `GET "/me");
  Alcotest.(check (list (pair string string)))
    "nothing held" []
    (Spindle.Test.Browser.cookies b);
  check_string "a cookie is set at its path" "seated" (call `POST "/games/1");
  check_string "and sent under it" "1" (call `GET "/games/1/seat");
  check_string "and not under another" "none" (call `GET "/games/2/seat");
  check_string "nor past its age" "none" (call ~now:61_000 `GET "/games/1/seat")

let test_a_test_reads_a_stream_that_never_ends () =
  Eio_main.run @@ fun _ ->
  let told_gone = ref false in
  let forever =
    Spindle.get
      Spindle.Path.(s "ticks")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.events (fun send ->
                 let rec go n =
                   match
                     send (Printf.sprintf "id: %d\ndata: tick %d\n\n" n n)
                   with
                   | Ok () -> go (n + 1)
                   | Error _ as e ->
                       told_gone := true;
                       e
                 in
                 go 1))))
  and waits =
    Spindle.get
      Spindle.Path.(s "waits")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.events (fun send ->
                 let ( let* ) = Result.bind in
                 let* () = send "data: one\n\n" in
                 Eio.Fiber.await_cancel ()))))
  in
  let a = Spindle.Test.app [ forever; waits; hello ] in
  let seen = ref [] in
  (match
     Spindle.Test.events a "/ticks" (fun e ->
         seen := (e.data, e.id) :: !seen;
         if List.length !seen = 3 then `Stop else `Continue)
   with
  | Ok () -> ()
  | Error r -> Alcotest.failf "no stream: %d" r.status);
  Alcotest.(check (list (pair string (option string))))
    "three events, as a client reads them"
    [ ("tick 1", Some "1"); ("tick 2", Some "2"); ("tick 3", Some "3") ]
    (List.rev !seen);
  Alcotest.(check bool) "and the route told its client had gone" true !told_gone;
  (match Spindle.Test.events a "/waits" (fun _ -> `Stop) with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "a stream that waits is still a stream");
  match Spindle.Test.events a "/hello/kim" (fun _ -> `Continue) with
  | Error r ->
      check_int "an answer that is no stream is the answer" 200 r.status
  | Ok () -> Alcotest.fail "a JSON answer is no stream"

let test_json_is_only_json () =
  let with_type ct =
    (Spindle.Test.call
       (Spindle.Test.app [ echo ])
       `POST "/echo" ~body:{|{"name":"lee"}|}
       ~headers:(match ct with Some c -> [ ("content-type", c) ] | None -> []))
      .status
  in
  check_status "text/plain" 415 (with_type (Some "text/plain"));
  check_status "a form" 415
    (with_type (Some "application/x-www-form-urlencoded"));
  check_status "JSON" 201 (with_type (Some "application/json; charset=utf-8"));
  check_status "a JSON of its own kind" 201
    (with_type (Some "application/merge-patch+json"));
  check_status "none said" 201 (with_type None)

(* ------------------------------------------------------------------ *)
(* Logging *)

let src = Logs.Src.create "test.web" ~doc:"This suite's own"

module L = (val Logs.src_log src : Logs.LOG)

let captured ?(level = Some Logs.Debug) ?sources f =
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level ?sources
    ~out:(fun l -> lines := l :: !lines)
    ();
  f ();
  List.rev !lines

(* The default sink's writer is the program's, so a domain that logs can
   still end: one started by the first domain to log held that domain until
   the process was killed, and a server's shutdown with it. A join that
   returns is the whole test. *)
let test_a_domain_that_logs_can_end () =
  Spindle.Log.setup ~level:(Some Logs.Info) ();
  Domain.join
    (Domain.spawn (fun () ->
         Logs.info (fun m -> m "a line from a domain of its own")))

(* What a line says, the rest of it read past. *)
let message =
  Wiretype.Object.(map (fun m -> m) |> mem "message" Wiretype.string |> finish)

(* The default sink, as a program uses it: this suite run again as a child
   that logs and exits, its stderr read here. Each domain logs beside a
   thread of its own, which shares its buffers, and its last line from an
   [at_exit] that runs after the log's own. Every line must arrive whole, in
   its writer's order, the last ones by the exit's flush. *)
let child_domains = 4
let child_lines = 5_000

(* Writer [d] is domain [d]; writer [child_domains + d] is its thread. *)
let log_child () =
  Spindle.Log.setup ~format:Spindle.Log.Json ();
  let log_lines writer =
    for n = 0 to child_lines - 1 do
      Logs.info (fun m -> m "%d %d" writer n)
    done
  in
  List.iter Domain.join
    (List.init child_domains (fun d ->
         Domain.spawn (fun () ->
             Domain.at_exit (fun () ->
                 Logs.info (fun m -> m "%d %d" d child_lines));
             let thread = Thread.create log_lines (child_domains + d) in
             log_lines d;
             Thread.join thread)))

let () =
  if Option.is_some (Sys.getenv_opt "SPINDLE_LOG_CHILD") then begin
    log_child ();
    exit 0
  end

let test_every_line_reaches_stderr_whole () =
  let read, write = Unix.pipe ~cloexec:true () in
  let child =
    Unix.create_process_env Sys.executable_name [| Sys.executable_name |]
      (Array.append [| "SPINDLE_LOG_CHILD=1" |] (Unix.environment ()))
      Unix.stdin Unix.stdout write
  in
  Unix.close write;
  let lines = In_channel.input_lines (Unix.in_channel_of_descr read) in
  Unix.close read;
  (* A signal another case installed a handler for interrupts the wait. *)
  let rec wait () =
    match Unix.waitpid [] child with
    | status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
  in
  (match wait () with
  | _, Unix.WEXITED 0 -> ()
  | _ -> Alcotest.fail "the child did not exit cleanly");
  let writers = 2 * child_domains in
  let next = Array.make writers 0 in
  List.iter
    (fun line ->
      match Wiretype.decode message line with
      | Error _ -> Alcotest.failf "not a whole line: %S" line
      | Ok message -> (
          match String.split_on_char ' ' message with
          | [ d; n ] -> (
              match (int_of_string_opt d, int_of_string_opt n) with
              | Some d, Some n when d >= 0 && d < writers ->
                  if n <> next.(d) then
                    Alcotest.failf "writer %d: line %d where %d was due" d n
                      next.(d);
                  next.(d) <- n + 1
              | _ -> Alcotest.failf "not the child's: %S" message)
          | _ -> Alcotest.failf "not the child's: %S" message))
    lines;
  Array.iteri
    (fun d n ->
      let expected =
        if d < child_domains then child_lines + 1 else child_lines
      in
      check_int (Printf.sprintf "writer %d's lines" d) expected n)
    next

(* A printer that logs while its own line is being formatted writes a line
   of its own, and neither is written into the other. *)
let test_a_printer_that_logs_writes_its_own_line () =
  let inner ppf () =
    L.info (fun m -> m "inner");
    Format.pp_print_string ppf "done"
  in
  let messages =
    List.map
      (fun line ->
        match Wiretype.decode message line with
        | Ok m -> m
        | Error _ -> Alcotest.failf "not a whole line: %S" line)
      (captured (fun () ->
           L.info (fun m -> m "outer %a" inner ());
           L.info (fun m -> m "after")))
  in
  Alcotest.(check (list string))
    "each its own"
    [ "inner"; "outer done"; "after" ]
    messages

let test_a_line_is_one_json_object () =
  match
    captured (fun () ->
        L.info (fun m ->
            m "moved %s" "d4"
              ~tags:
                (Spindle.Log.tags
                   [
                     ("http.response.status_code", `Int 202);
                     ("ok", `Bool true);
                     ("said", `String "a \"quote\"\n");
                     ("ms", `Float 0.1);
                     ("big", `Int (1 lsl 60));
                   ])))
  with
  | [ line ] -> (
      match Wiretype.decode Wiretype.Value.json line with
      | Error m ->
          Alcotest.failf "not JSON: %s (%s)"
            (Wiretype.Problem.list_to_string m)
            line
      | Ok _ ->
          List.iter
            (fun sub -> Alcotest.(check bool) sub true (contains ~sub line))
            [
              {|"level":"info"|};
              {|"logger.name":"test.web"|};
              {|"message":"moved d4"|};
              {|"http.response.status_code":202|};
              {|"ok":true|};
              {|"said":"a \"quote\"\n"|};
              {|"ms":0.1|};
              {|"big":"1152921504606846976"|};
            ];
          (* 2026-09-28T14:03:07.042Z, in UTC to the millisecond. *)
          let time = String.sub line 14 24 in
          String.iteri
            (fun i c ->
              let ok =
                match (i, c) with
                | (4 | 7), '-' | 10, 'T' | (13 | 16), ':' | 19, '.' | 23, 'Z' ->
                    true
                | (4 | 7 | 10 | 13 | 16 | 19 | 23), _ -> false
                | _, c -> c >= '0' && c <= '9'
              in
              if not ok then Alcotest.failf "not an ISO time: %s" time)
            time;
          Alcotest.(check bool)
            "the line begins with it" true
            (String.starts_with ~prefix:{|{"timestamp":"|} line))
  | lines -> Alcotest.failf "expected one line, got %d" (List.length lines)

let test_levels_are_read_from_a_spec () =
  (match Spindle.Log.configure ~levels:(Some "loud") ~format:None with
  | Ok () -> Alcotest.fail "a level that is not one was read"
  | Error m -> Alcotest.(check bool) "names it" true (contains ~sub:"loud" m));
  (match Spindle.Log.configure ~levels:None ~format:(Some "xml") with
  | Ok () -> Alcotest.fail "a format that is not one was read"
  | Error _ -> ());
  (* What a Makefile exports when its .env sets nothing: an empty string,
     which is no setting at all and must not stop a server starting. *)
  (match Spindle.Log.configure ~levels:(Some "") ~format:(Some " ") with
  | Ok () -> ()
  | Error m -> Alcotest.failf "a blank setting was refused: %s" m);
  match
    Spindle.Log.configure ~levels:(Some "warn,test.web=debug") ~format:None
  with
  | Error m -> Alcotest.fail m
  | Ok () ->
      Alcotest.(check bool)
        "the named source is turned up" true
        (match Logs.Src.level src with Some Logs.Debug -> true | _ -> false);
      Alcotest.(check bool)
        "and everything else is at the level given" true
        (match Logs.level () with Some Logs.Warning -> true | _ -> false)

(* At debug, TLS tracing writes the records themselves -- every header of
   every call inside them. Turning everything up must not turn that on. *)
let test_the_wire_is_not_raised_by_the_everything_level () =
  ignore (captured ~level:(Some Logs.Debug) ignore);
  List.iter
    (fun src ->
      if String.equal (Logs.Src.name src) "tls.tracing" then
        Alcotest.(check bool)
          "the transcript stays at warn" true
          (match Logs.Src.level src with
          | Some Logs.Warning -> true
          | _ -> false))
    (Logs.Src.list ());
  ignore (captured ~sources:[ ("tls.tracing", Some Logs.Debug) ] ignore);
  List.iter
    (fun src ->
      if String.equal (Logs.Src.name src) "tls.tracing" then
        Alcotest.(check bool)
          "unless it is named" true
          (match Logs.Src.level src with Some Logs.Debug -> true | _ -> false))
    (Logs.Src.list ())

(* A blocking call runs on a systhread, where a fiber's binding cannot be
   read. [carry] is what takes the request's id there. *)
let test_the_request_id_crosses_to_a_thread () =
  Eio_main.run @@ fun _env ->
  let seen_bare = ref (Some "unset") and seen_carried = ref None in
  let trace = ref None and carried_trace = ref None in
  Spindle.Log.with_request_id "r-1" (fun () ->
      trace := Spindle.Log.trace_id ();
      Alcotest.(check (option string))
        "on the fiber" (Some "r-1")
        (Spindle.Log.request_id ());
      let bare () = seen_bare := Spindle.Log.request_id () in
      let carried =
        Spindle.Log.carry (fun () ->
            seen_carried := Spindle.Log.request_id ();
            carried_trace := Spindle.Log.trace_id ())
      in
      Thread.join (Thread.create bare ());
      Thread.join (Thread.create carried ()));
  Alcotest.(check (option string)) "not by itself" None !seen_bare;
  Alcotest.(check (option string)) "but carried" (Some "r-1") !seen_carried;
  Alcotest.(check (option string)) "with its trace" !trace !carried_trace;
  Alcotest.(check (option string))
    "and gone after" None
    (Spindle.Log.request_id ())

(* A request joins the trace its caller sent, as a span of its own, and
   begins one of its own for anything that is not a W3C traceparent -- so a
   mangled header costs a trace, never a request. *)
let sent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
let sent_trace = "4bf92f3577b34da6a3ce929d0e0e4736"

let test_a_request_joins_the_trace_it_was_sent () =
  Eio_main.run @@ fun _env ->
  let hex n s =
    String.length s = n
    && String.for_all
         (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
         s
  in
  let seen =
    Spindle.get
      Spindle.Path.(s "seen")
      Spindle.Returns.text
      (Spindle.Dep.of_request (fun _ ->
           let v f = Option.value (f ()) ~default:"-" in
           Ok
             (Ok
                (String.concat " "
                   [
                     v Spindle.Log.trace_id;
                     v Spindle.Log.span_id;
                     v Spindle.Log.traceparent;
                   ]))))
  in
  let app = Spindle.Test.app [ seen ] in
  let ask headers =
    match
      String.split_on_char ' '
        (Spindle.Test.call app ~headers `GET "/seen").body
    with
    | [ trace; span; onward ] -> (trace, span, onward)
    | _ -> Alcotest.fail "three ids"
  in
  let trace, span, onward = ask [ ("traceparent", sent) ] in
  check_string "its trace is the caller's" sent_trace trace;
  Alcotest.(check bool) "its span is its own" true (hex 16 span);
  Alcotest.(check bool)
    "and not the caller's" false
    (String.equal span "00f067aa0ba902b7");
  (match String.split_on_char '-' onward with
  | [ "00"; t; s; "01" ] ->
      check_string "a call carries the trace on" sent_trace t;
      Alcotest.(check bool)
        "as a span of the call's own" false
        (String.equal s span || String.equal s "00f067aa0ba902b7")
  | _ -> Alcotest.failf "not a traceparent: %s" onward);
  let trace, span, _ = ask [] in
  Alcotest.(check bool) "without one, a trace begins" true (hex 32 trace);
  Alcotest.(check bool) "with a span" true (hex 16 span);
  List.iter
    (fun (why, v) ->
      let trace, _, _ = ask [ ("traceparent", v) ] in
      Alcotest.(check bool) why true (hex 32 trace);
      Alcotest.(check bool)
        (why ^ ", not joined") false
        (String.equal trace sent_trace))
    [
      ("upper case", "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01");
      ( "a trace of zeros",
        "00-00000000000000000000000000000000-00f067aa0ba902b7-01" );
      ( "a parent of zeros",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01" );
      ("version ff", "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
      ("cut short", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0");
      ("00 with more after it", sent ^ "-extra");
      ( "a dash out of place",
        "00-4bf92f3577b34da6a3ce929d0e0e4736_00f067aa0ba902b7-01" );
    ];
  let trace, _, onward =
    ask
      [
        ( "traceparent",
          "cc-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-03-what-next" );
      ]
  in
  check_string "a later version is read as its first four parts" sent_trace
    trace;
  Alcotest.(check bool)
    "and passed on as 00, with the sampled bit alone" true
    (String.starts_with ~prefix:"00-" onward
    && String.ends_with ~suffix:"-01" onward);
  let _, _, onward =
    ask
      [
        ( "traceparent",
          "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00" );
      ]
  in
  Alcotest.(check bool)
    "unsampled stays unsampled" true
    (String.ends_with ~suffix:"-00" onward)

(* A line logged for a request carries its trace beside its id. *)
let test_a_line_carries_the_trace () =
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  Eio_main.run @@ fun _env ->
  Spindle.Log.with_request_id ~traceparent:sent "r-1" (fun () ->
      Logs.info (fun m -> m "for the request"));
  match !lines with
  | [ line ] ->
      List.iter
        (fun sub -> Alcotest.(check bool) sub true (contains ~sub line))
        [
          {|"request_id":"r-1"|};
          Printf.sprintf {|"trace_id":"%s"|} sent_trace;
          {|"span_id":"|};
        ]
  | lines -> Alcotest.failf "expected one line, got %d" (List.length lines)

(* Work posted from a domain Spindle does not run keeps the trace of the
   request that asked for it. *)
let test_posted_work_keeps_the_trace () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let background = Spindle.Background.create ~sw in
  let seen, see = Eio.Promise.create () in
  Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
      Spindle.Log.with_request_id ~traceparent:sent "r-2" (fun () ->
          Spindle.Background.fork background ~what:"posted" (fun () ->
              Eio.Promise.resolve see
                (Spindle.Log.request_id (), Spindle.Log.trace_id ()))));
  let id, trace = Eio.Promise.await seen in
  Alcotest.(check (option string)) "its request" (Some "r-2") id;
  Alcotest.(check (option string)) "and its trace" (Some sent_trace) trace

(* A call made for a request sends its trace, unless the caller named one. *)
let test_a_call_carries_the_trace () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let arrived = ref [] in
  let port =
    Stub_server.serve ~sw ~net (fun req ->
        arrived := Stub_server.header req "traceparent" :: !arrived;
        Stub_server.reply `OK "")
  in
  let client =
    Spindle_client.create ~sw ~net ~mono_clock:(Eio.Stdenv.mono_clock env) ()
  in
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  let call ?headers () =
    match Spindle_client.call client ?headers `GET url with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Spindle_client.error_to_string e)
  in
  call ();
  Spindle.Log.with_request_id ~traceparent:sent "r-3" (fun () ->
      call ();
      call
        ~headers:
          [
            ( "traceparent",
              "00-" ^ String.make 32 'a' ^ "-" ^ String.make 16 'b' ^ "-00" );
          ]
        ());
  match List.rev !arrived with
  | [ outside; inside; named ] ->
      Alcotest.(check (option string)) "nothing outside a request" None outside;
      (match inside with
      | Some v ->
          Alcotest.(check bool)
            "the request's trace" true
            (String.starts_with ~prefix:("00-" ^ sent_trace ^ "-") v)
      | None -> Alcotest.fail "no traceparent");
      Alcotest.(check (option string))
        "the caller's own wins"
        (Some ("00-" ^ String.make 32 'a' ^ "-" ^ String.make 16 'b' ^ "-00"))
        named
  | l -> Alcotest.failf "expected three calls, got %d" (List.length l)

(* ------------------------------------------------------------------ *)
(* Spans *)

(* What an exporter was handed, from any domain. *)
(* What an exporter recorded, and a wait until it holds what a test
   expects: a server records a span after its answer is written, which can
   be after the client has read it. *)
let recorder () =
  let spans = ref [] and lock = Mutex.create () in
  let changed = Eio.Condition.create () in
  let recorded () = Mutex.protect lock (fun () -> List.rev !spans) in
  let record span =
    Mutex.protect lock (fun () -> spans := span :: !spans);
    Eio.Condition.broadcast changed
  in
  let until holds =
    Eio.Condition.loop_no_mutex changed (fun () ->
        let spans = recorded () in
        if holds spans then Some spans else None)
  in
  (record, recorded, until)

let exporter ?ratio env record =
  Spindle.Trace.exporter ?ratio ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    record

let test_a_kept_trace_records_its_spans () =
  Eio_main.run @@ fun env ->
  let record, recorded, _ = recorder () in
  let trace = exporter env record in
  let onward = ref None in
  Spindle.Log.with_request_id ~trace "r-1" (fun () ->
      Spindle.Trace.span "price the order"
        ~attributes:[ ("items", `Int 3) ]
        (fun () -> onward := Spindle.Log.traceparent ());
      try Spindle.Trace.span "look it up" (fun () -> raise Not_found)
      with Not_found -> ());
  match recorded () with
  | [ price; lookup; request ] ->
      Alcotest.(check bool)
        "the request is a server span, named until a server names it" true
        (request.kind = Spindle.Trace.Server
        && String.equal request.name "request"
        && Option.is_none request.parent_id);
      Alcotest.(check (option string))
        "a span is a child of the request's" (Some request.span_id)
        price.parent_id;
      check_string "in its trace" request.trace_id price.trace_id;
      Alcotest.(check bool)
        "with its attributes, of its own kind" true
        (price.attributes = [ ("items", `Int 3) ]
        && price.kind = Spindle.Trace.Internal
        && price.status = Spindle.Trace.Unset);
      Alcotest.(check bool)
        "and a length" true
        (price.start_ns > 0 && price.end_ns >= price.start_ns);
      Alcotest.(check (option string))
        "a call inside it is its child"
        (Some (Printf.sprintf "00-%s-%s-01" request.trace_id price.span_id))
        !onward;
      Alcotest.(check bool)
        "a raise is its status, by constructor, and passes" true
        (lookup.status = Spindle.Trace.Error "Not_found"
        && List.mem ("exception.type", `String "Not_found") lookup.attributes)
  | spans -> Alcotest.failf "expected three spans, got %d" (List.length spans)

(* A trace begun here is kept at the ratio; one joined is kept exactly when
   the caller's is, so a trace is whole or absent. *)
let test_a_trace_is_kept_whole_or_not_at_all () =
  Eio_main.run @@ fun env ->
  let spans_of ?ratio ?traceparent () =
    let record, recorded, _ = recorder () in
    let onward = ref None in
    Spindle.Log.with_request_id ?traceparent ~trace:(exporter ?ratio env record)
      "r" (fun () ->
        Spindle.Trace.span "inside" (fun () ->
            onward := Spindle.Log.traceparent ()));
    (recorded (), !onward)
  in
  let none, onward = spans_of ~ratio:0. () in
  check_int "a root at none is not kept" 0 (List.length none);
  Alcotest.(check bool)
    "and says so onward" true
    (match onward with
    | Some v -> String.ends_with ~suffix:"-00" v
    | None -> false);
  let joined, _ = spans_of ~ratio:0. ~traceparent:sent () in
  check_int "a caller's kept trace is kept at any ratio" 2 (List.length joined);
  Alcotest.(check bool)
    "under the caller's span" true
    (List.exists
       (fun (sp : Spindle.Trace.span) ->
         sp.parent_id = Some "00f067aa0ba902b7"
         && String.equal sp.trace_id sent_trace)
       joined);
  let dropped, _ =
    spans_of
      ~traceparent:"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00" ()
  in
  check_int "and one it did not keep is not, at any ratio" 0
    (List.length dropped)

(* A caller's tracestate goes on beside the trace it came with. *)
let test_a_tracestate_is_passed_on () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let arrived = ref [] in
  let port =
    Stub_server.serve ~sw ~net (fun req ->
        arrived := Stub_server.header req "tracestate" :: !arrived;
        Stub_server.reply `OK "")
  in
  let client =
    Spindle_client.create ~sw ~net ~mono_clock:(Eio.Stdenv.mono_clock env) ()
  in
  let call () =
    match
      Spindle_client.call client `GET
        (Printf.sprintf "http://127.0.0.1:%d/" port)
    with
    | Ok _ -> ()
    | Error e -> Alcotest.fail (Spindle_client.error_to_string e)
  in
  Spindle.Log.with_request_id ~traceparent:sent ~tracestate:"shop=1,bank=2" "r"
    call;
  Spindle.Log.with_request_id ~tracestate:"shop=1" "r" call;
  Spindle.Log.with_request_id ~traceparent:sent
    ~tracestate:(String.make 513 'a') "r" call;
  Alcotest.(check (list (option string)))
    "with its trace, never without one, and never past 512 characters"
    [ Some "shop=1,bank=2"; None; None ]
    (List.rev !arrived)

(* A request, the call it made to another Spindle server and that server's
   answer are one trace of three spans -- and a statement run inside one is
   a fourth -- carrying no header value and no query. *)
let test_a_request_and_its_call_are_one_trace () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let record, _, until = recorder () in
  let trace = exporter env record in
  let client =
    Spindle_client.create ~sw ~net ~mono_clock:(Eio.Stdenv.mono_clock env) ()
  in
  let port = ref 0 in
  let front =
    Spindle.get
      Spindle.Path.(s "front")
      Spindle.Returns.text
      (Spindle.Dep.of_request (fun _ ->
           match
             Spindle_client.call client `GET
               (Printf.sprintf "http://127.0.0.1:%d/back/7?code=hunter2" !port)
           with
           | Ok r -> Ok (Ok r.body)
           | Error e -> Alcotest.fail (Spindle_client.error_to_string e)))
  and back =
    Spindle.get
      Spindle.Path.(s "back" / Spindle.Path.int "n")
      Spindle.Returns.text
      (let+ n = Spindle.param (Spindle.Path.int "n") in
       Ok (string_of_int n))
  and broken =
    Spindle.get
      Spindle.Path.(s "broken")
      Spindle.Returns.text
      (Spindle.Dep.of_request (fun _ -> failwith "a bug"))
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  (port :=
     match Eio.Net.listening_addr socket with
     | `Tcp (_, p) -> p
     | _ -> Alcotest.fail "expected a TCP socket");
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains:1
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~now:(fun () -> 0)
        ~trace [ socket ]
        (Spindle.Test.app [ front; back; broken ]);
      `Stop_daemon);
  let outside =
    Spindle_client.create ~sw ~net ~mono_clock:(Eio.Stdenv.mono_clock env) ()
  in
  let ask path =
    match
      Spindle_client.call outside
        ~headers:[ ("authorization", "Bearer hunter2") ]
        `GET
        (Printf.sprintf "http://127.0.0.1:%d%s" !port path)
    with
    | Ok r -> r
    | Error e -> Alcotest.fail (Spindle_client.error_to_string e)
  in
  check_string "the front answers the back's answer" "7"
    (ask "/front?code=hunter2").body;
  let spans = until (fun spans -> List.length spans >= 3) in
  let named name =
    match
      List.find_opt
        (fun (sp : Spindle.Trace.span) -> String.equal sp.name name)
        spans
    with
    | Some sp -> sp
    | None -> Alcotest.failf "no span named %S" name
  in
  let front = named "GET /front"
  and call = named "GET"
  and back = named "GET /back/{n}" in
  check_int "three spans" 3 (List.length spans);
  Alcotest.(check bool)
    "one trace" true
    (String.equal front.trace_id call.trace_id
    && String.equal call.trace_id back.trace_id);
  Alcotest.(check (option string))
    "the call is the front's child" (Some front.span_id) call.parent_id;
  Alcotest.(check (option string))
    "and the back is the call's" (Some call.span_id) back.parent_id;
  Alcotest.(check bool)
    "each of its side" true
    (front.kind = Spindle.Trace.Server
    && call.kind = Spindle.Trace.Client
    && back.kind = Spindle.Trace.Server);
  Alcotest.(check bool)
    "a server span says what the access line says" true
    (List.mem ("http.route", `String "/front") front.attributes
    && List.mem ("http.response.status_code", `Int 200) front.attributes
    && List.mem ("url.path", `String "/front") front.attributes);
  Alcotest.(check bool)
    "and a call where it went" true
    (List.mem ("server.address", `String "127.0.0.1") call.attributes
    && List.mem ("url.path", `String "/back/7") call.attributes
    && List.mem ("http.response.status_code", `Int 200) call.attributes);
  List.iter
    (fun (sp : Spindle.Trace.span) ->
      List.iter
        (fun (k, v) ->
          match v with
          | `String v when contains ~sub:"hunter2" v ->
              Alcotest.failf "%s's %s carries a secret: %s" sp.name k v
          | `String _ | `Int _ | `Float _ | `Bool _ -> ())
        sp.attributes)
    spans;
  check_int "a bug is a 500" 500 (ask "/broken").status;
  let is_broken (sp : Spindle.Trace.span) =
    String.equal sp.name "GET /broken"
  in
  Alcotest.(check bool)
    "and its span failed" true
    (List.exists
       (fun (sp : Spindle.Trace.span) ->
         is_broken sp && sp.status = Spindle.Trace.Error "500")
       (until (List.exists is_broken)))

(* The exporter posts OTLP's JSON, a batch at a time, and says what it
   dropped. *)
let test_spans_reach_a_collector () =
  let lines = ref [] and lock = Mutex.create () in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> Mutex.protect lock (fun () -> lines := l :: !lines))
    ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let posted = ref [] in
  let port =
    Stub_server.serve ~sw ~net (fun req ->
        posted := req :: !posted;
        Stub_server.reply `OK "{}")
  in
  let client =
    Spindle_client.create ~sw ~net ~mono_clock:(Eio.Stdenv.mono_clock env) ()
  in
  Spindle_client.Otlp.run ~clock:(Eio.Stdenv.clock env)
    ~endpoint:(Printf.sprintf "http://127.0.0.1:%d/" port)
    ~service:"shop"
    ~headers:[ ("x-collector-key", "k") ]
    client
    (fun trace ->
      Spindle.Log.with_request_id ~trace "r-1" (fun () ->
          Spindle.Trace.span "price"
            ~attributes:
              [
                ("items", `Int 3);
                ("ok", `Bool true);
                ("rate", `Float 0.5);
                ("who", `String "kim");
              ]
            ignore);
      Spindle.Log.with_request_id ~trace "r-2" (fun () ->
          for _ = 1 to 2100 do
            Spindle.Trace.span "tick" ignore
          done));
  let open Yojson.Safe.Util in
  let posts = List.rev !posted in
  List.iter
    (fun (r : Stub_server.request) ->
      check_string "to /v1/traces" "/v1/traces" r.path;
      Alcotest.(check (option string))
        "as JSON" (Some "application/json")
        (Stub_server.header r "content-type");
      Alcotest.(check (option string))
        "with the collector's credential" (Some "k")
        (Stub_server.header r "x-collector-key"))
    posts;
  let spans =
    List.concat_map
      (fun (r : Stub_server.request) ->
        let resource =
          Yojson.Safe.from_string r.body
          |> member "resourceSpans" |> to_list |> List.hd
        in
        Alcotest.(check string)
          "under the service's name" "shop"
          (resource |> member "resource" |> member "attributes" |> to_list
         |> List.hd |> member "value" |> member "stringValue" |> to_string);
        resource |> member "scopeSpans" |> to_list |> List.hd |> member "spans"
        |> to_list)
      posts
  in
  check_int "every span the queue held" 2048 (List.length spans);
  Alcotest.(check bool)
    "a batch at most to a post" true
    (List.for_all
       (fun (r : Stub_server.request) ->
         List.length
           (Yojson.Safe.from_string r.body
           |> member "resourceSpans" |> to_list |> List.hd
           |> member "scopeSpans" |> to_list |> List.hd |> member "spans"
           |> to_list)
         <= 512)
       posts);
  let price =
    List.find
      (fun sp -> String.equal (sp |> member "name" |> to_string) "price")
      spans
  and request =
    List.find
      (fun sp ->
        String.equal (sp |> member "name" |> to_string) "request"
        && Option.is_none (sp |> member "parentSpanId" |> to_option to_string))
      spans
  in
  check_int "an internal span is kind 1" 1 (price |> member "kind" |> to_int);
  check_int "a server span kind 2" 2 (request |> member "kind" |> to_int);
  check_string "its parent in hex"
    (request |> member "spanId" |> to_string)
    (price |> member "parentSpanId" |> to_string);
  Alcotest.(check bool)
    "an instant is a decimal string" true
    (String.for_all
       (function '0' .. '9' -> true | _ -> false)
       (price |> member "startTimeUnixNano" |> to_string));
  let attribute key =
    List.find
      (fun a -> String.equal (a |> member "key" |> to_string) key)
      (price |> member "attributes" |> to_list)
    |> member "value"
  in
  check_string "an integer as a string" "3"
    (attribute "items" |> member "intValue" |> to_string);
  Alcotest.(check bool)
    "a boolean" true
    (attribute "ok" |> member "boolValue" |> to_bool);
  Alcotest.(check (float 0.))
    "a float" 0.5
    (attribute "rate" |> member "doubleValue" |> to_number);
  check_string "a string" "kim"
    (attribute "who" |> member "stringValue" |> to_string);
  Alcotest.(check bool)
    "and what the queue could not hold, said" true
    (List.exists
       (fun l -> contains ~sub:"dropped 55 spans" l)
       (Mutex.protect lock (fun () -> !lines)))

(* A batch is sent once it is whole, not at the next tick -- even one that
   filled while the sender was out posting the last. *)
let test_a_whole_batch_is_sent_without_waiting_for_the_tick () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and mono_clock = Eio.Stdenv.mono_clock env in
  let posts = Eio.Stream.create 8 in
  let release, let_go = Eio.Promise.create () in
  let first = ref true in
  let port =
    Stub_server.serve ~sw ~net (fun _ ->
        Eio.Stream.add posts ();
        if !first then (
          first := false;
          Eio.Promise.await release);
        Stub_server.reply `OK "{}")
  in
  let client = Spindle_client.create ~sw ~net ~mono_clock () in
  Spindle_client.Otlp.run ~clock:(Eio.Stdenv.clock env)
    ~endpoint:(Printf.sprintf "http://127.0.0.1:%d" port) ~service:"shop" client
    (fun trace ->
      let spans n =
        Spindle.Log.with_request_id ~trace "r" (fun () ->
            for _ = 1 to n do
              Spindle.Trace.span "tick" ignore
            done)
      in
      spans 1;
      (* The tick's post, held at the collector while a batch fills. *)
      Eio.Stream.take posts;
      spans 600;
      Eio.Promise.resolve let_go ();
      match
        Eio.Time.Timeout.run (Eio.Time.Timeout.seconds mono_clock 2.) (fun () ->
            Ok (Eio.Stream.take posts))
      with
      | Ok () -> ()
      | Error `Timeout -> Alcotest.fail "the whole batch waited for the tick")

(* ------------------------------------------------------------------ *)
(* Metrics *)

let test_metrics_are_written_as_prometheus_reads_them () =
  let m = Spindle.Metrics.create () in
  let hits =
    Spindle.Metrics.counter m ~help:"Pages served" ~labels:[ "shop.page" ]
      "shop.hits"
  in
  let carts = Spindle.Metrics.gauge m "shop.carts" in
  Spindle.Metrics.sampled m ~unit:"bytes" "shop.cache" (fun () -> [ ([], 1.5) ]);
  let upload =
    Spindle.Metrics.histogram m ~unit:"bytes" ~labels:[ "kind" ]
      ~buckets:[ 10.; 100. ] "shop.upload"
  in
  Spindle.Metrics.inc hits [ "home" ];
  Spindle.Metrics.inc ~by:2 hits [ "a \"quoted\"\\ line\n" ];
  Spindle.Metrics.inc hits [ "" ];
  Spindle.Metrics.add carts [] 3;
  Spindle.Metrics.add carts [] (-1);
  List.iter (Spindle.Metrics.observe upload [ "photo" ]) [ 5.; 50.; 500.5 ];
  check_string "the text format"
    (String.concat "\n"
       [
         "# HELP shop_hits_total Pages served";
         "# TYPE shop_hits_total counter";
         {|shop_hits_total{shop_page="home"} 1|};
         {|shop_hits_total{shop_page="a \"quoted\"\\ line\n"} 2|};
         "shop_hits_total 1";
         "# TYPE shop_carts gauge";
         "shop_carts 2";
         "# TYPE shop_cache_bytes gauge";
         "shop_cache_bytes 1.5";
         "# TYPE shop_upload_bytes histogram";
         {|shop_upload_bytes_bucket{kind="photo",le="10"} 1|};
         {|shop_upload_bytes_bucket{kind="photo",le="100"} 2|};
         {|shop_upload_bytes_bucket{kind="photo",le="+Inf"} 3|};
         {|shop_upload_bytes_sum{kind="photo"} 555.5|};
         {|shop_upload_bytes_count{kind="photo"} 3|};
         "";
       ])
    (Spindle.Metrics.exposition m)

(* Each domain counts into a cell of its own, and a reading sums them. *)
let test_every_domain_counts_into_one_series () =
  Eio_main.run @@ fun env ->
  let m = Spindle.Metrics.create () in
  let hits = Spindle.Metrics.counter m ~labels:[ "page" ] "hits" in
  let sizes = Spindle.Metrics.histogram m ~labels:[ "page" ] "sizes" in
  Eio.Fiber.List.iter
    (fun () ->
      Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
          for _ = 1 to 1000 do
            Spindle.Metrics.inc hits [ "home" ];
            Spindle.Metrics.observe sizes [ "home" ] 0.5
          done))
    [ (); (); (); () ];
  let text = Spindle.Metrics.exposition m in
  List.iter
    (fun line -> Alcotest.(check bool) line true (contains ~sub:line text))
    [
      {|hits_total{page="home"} 4000|};
      {|sizes_count{page="home"} 4000|};
      {|sizes_sum{page="home"} 2000|};
    ]

let test_a_metric_that_cannot_be_exposed_is_refused () =
  let m = Spindle.Metrics.create () in
  let hits = Spindle.Metrics.counter m ~labels:[ "page" ] "hits" in
  List.iter
    (fun (why, f) ->
      match f () with
      | () -> Alcotest.failf "%s: accepted" why
      | exception Invalid_argument _ -> ())
    [
      ( "a name that is no name",
        fun () -> ignore (Spindle.Metrics.gauge m "9 lives") );
      ("a name twice", fun () -> ignore (Spindle.Metrics.gauge m "hits"));
      ( "a histogram's own label",
        fun () -> ignore (Spindle.Metrics.gauge m ~labels:[ "le" ] "g") );
      ( "buckets that fall",
        fun () -> ignore (Spindle.Metrics.histogram m ~buckets:[ 1.; 0.5 ] "h")
      );
      ("too few values", fun () -> Spindle.Metrics.inc hits []);
      ("too many", fun () -> Spindle.Metrics.inc hits [ "a"; "b" ]);
      ( "a counter moved down",
        fun () -> Spindle.Metrics.inc ~by:(-1) hits [ "home" ] );
    ];
  Spindle.Metrics.sampled m ~labels:[ "pool" ] "pools" (fun () ->
      [ ([ "a" ], 1.) ]);
  Spindle.Metrics.sampled m ~labels:[ "pool" ] "pools" (fun () ->
      [ ([ "b" ], 2.) ]);
  Alcotest.(check bool)
    "but a sampled gauge twice is two readers" true
    (contains ~sub:"pools{pool=\"a\"} 1\npools{pool=\"b\"} 2"
       (Spindle.Metrics.exposition m));
  Spindle.Metrics.sampled m ~labels:[ "pool" ] "pools" (fun () ->
      [ ([], 3.); ([ "c" ], 4.) ]);
  let page = Spindle.Metrics.exposition m in
  Alcotest.(check bool)
    "a series with the wrong number of values is left out, the page kept" true
    (contains ~sub:"pools{pool=\"c\"} 4" page
    && not (contains ~sub:"pools 3" page))

(* A server counts its requests by method, route and status -- a request no
   route answered under no route, a method HTTP does not name as [_OTHER]
   -- and its connections and body budget beside them. *)
let test_a_server_counts_its_requests () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let metrics = Spindle.Metrics.create () in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains:2
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~now:(fun () -> 0)
        ~metrics [ socket ]
        (Spindle.Test.app (hello :: Spindle.Metrics.routes metrics));
      `Stop_daemon);
  (* A request is counted out after its answer is written, which can be
     after the client has read it; its connection closes only once it is,
     so a request read to the end of a closed connection is counted. *)
  let ask meth path =
    Eio.Switch.run @@ fun inner ->
    let flow =
      Eio.Net.connect ~sw:inner net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    Eio.Flow.copy_string
      (Printf.sprintf "%s %s HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
         meth path)
      flow;
    Eio.Buf_read.(parse_exn take_all) flow ~max_size:1_000_000
  in
  Alcotest.(check bool)
    "one" true
    (String.starts_with ~prefix:"HTTP/1.1 200" (ask "GET" "/hello/kim"));
  Alcotest.(check bool)
    "two" true
    (String.starts_with ~prefix:"HTTP/1.1 200" (ask "GET" "/hello/lee"));
  Alcotest.(check bool)
    "nobody's" true
    (String.starts_with ~prefix:"HTTP/1.1 404" (ask "GET" "/nowhere/at/all"));
  ignore (ask "BREW" "/hello/kim" : string);
  let text = ask "GET" "/metrics" in
  List.iter
    (fun line -> Alcotest.(check bool) line true (contains ~sub:line text))
    [
      {|http_server_request_duration_seconds_count{http_request_method="GET",http_route="/hello/{name}",http_response_status_code="200"} 2|};
      {|http_server_request_duration_seconds_count{http_request_method="GET",http_response_status_code="404"} 1|};
      {|http_request_method="_OTHER"|};
      (* The scrape itself is the one being answered. *)
      "http_server_active_requests 1\n";
      "# TYPE spindle_server_open_connections gauge";
      "spindle_server_body_budget_used_bytes 0";
    ];
  Alcotest.(check bool)
    "and never a path" false
    (contains ~sub:"/hello/kim" text || contains ~sub:"nowhere" text)

let test_metrics_are_guarded_as_a_route_is () =
  let forbidden = code "forbidden" `Forbidden in
  let guard =
    Spindle.Dep.of_request ~refuses:[ forbidden ] (fun req ->
        match Spindle.Request.header req "authorization" with
        | Some "Bearer scraper" -> Ok ()
        | Some _ | None -> Error (Spindle.Refusal.make forbidden "Not you."))
  in
  let m = Spindle.Metrics.create () in
  ignore (Spindle.Metrics.gauge m "up");
  let app = Spindle.Test.app (Spindle.Metrics.routes ~guard m) in
  check_status "refused without" 403
    (Spindle.Test.call app `GET "/metrics").status;
  let r =
    Spindle.Test.call app
      ~headers:[ ("authorization", "Bearer scraper") ]
      `GET "/metrics"
  in
  check_status "and read with" 200 r.status;
  check_string "the exposition" "# TYPE up gauge\n" r.body

(* ------------------------------------------------------------------ *)
(* Calling out *)

(* A server of the framework's own on a loopback socket, and the client
   calling it: an answer, a deadline that passes, and nobody listening. *)
let test_the_client_answers_times_out_and_reports domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  (* It never answers, so a call to it passes any deadline. *)
  let slow =
    Spindle.get
      Spindle.Path.(s "slow")
      Spindle.Returns.response
      (Spindle.Dep.of_request (fun _ -> Eio.Fiber.await_cancel ()))
  in
  let events =
    Spindle.get
      Spindle.Path.(s "events")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok (Spindle.Response.events (fun send -> send "data: 1\n\n"))))
  in
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let served = Spindle.Test.app [ hello; slow; events ] in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~now:(fun () -> 0)
        [ socket ] served;
      `Stop_daemon);
  let client =
    Spindle_client.create ~sw ~net ~mono_clock:(Eio.Stdenv.mono_clock env) ()
  and impatient =
    Spindle_client.create ~sw ~net
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~timeout_s:0.3 ()
  in
  let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  (match Spindle_client.call client `GET (url "/hello/kim") with
  | Ok r ->
      check_int "an answer" 200 r.status;
      check_string "its body" {|{"name":"kim","times":1}|} r.body;
      Alcotest.(check bool)
        "and its request id" true
        (List.mem_assoc "x-request-id" r.headers)
  | Error e -> Alcotest.fail (Spindle_client.error_to_string e));
  (* A call made for a request reaches the server as part of its trace. *)
  Spindle.Log.with_request_id ~traceparent:sent "r-4" (fun () ->
      match Spindle_client.call client `GET (url "/hello/kim") with
      | Ok _ -> ()
      | Error e -> Alcotest.fail (Spindle_client.error_to_string e));
  Alcotest.(check bool)
    "the server answers it in the caller's trace" true
    (List.exists
       (fun l ->
         contains ~sub:"GET /hello/kim 200" l
         && contains ~sub:(Printf.sprintf {|"trace_id":"%s"|} sent_trace) l
         && not (contains ~sub:{|"request_id":"r-4"|} l))
       !lines);
  (match Spindle_client.call impatient `GET (url "/slow") with
  | Error (Spindle_client.Timed_out _) -> ()
  | Ok _ | Error (Spindle_client.Unreachable _) ->
      Alcotest.fail "a call past its deadline should have been given up");
  (match Spindle_client.call client `GET (url "/events") with
  | Ok r ->
      check_string "a stream, framed and ended" "data: 1\n\n" r.body;
      (* The writer runs after the handler has returned, and its line must
         still say which request it was. *)
      Alcotest.(check bool)
        "its end is logged under its request" true
        (List.exists
           (fun l ->
             contains ~sub:"ended: finished" l
             && contains ~sub:{|"request_id":"|} l)
           !lines)
  | Error e -> Alcotest.fail (Spindle_client.error_to_string e));
  match Spindle_client.call client `GET "http://127.0.0.1:1/nobody" with
  | Error (Spindle_client.Unreachable _) -> ()
  | Ok _ | Error (Spindle_client.Timed_out _) ->
      Alcotest.fail "nobody listening is unreachable"

(* A handshake that fails -- here against a server that speaks no TLS and
   hangs up -- leaves no socket behind: the one it was tried on is closed
   with it, rather than left on the domain's switch for the life of the
   process. *)
let test_a_failed_handshake_leaves_no_socket () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec hang_up () =
        Eio.Net.accept_fork socket ~sw ~on_error:ignore (fun _ _ -> ());
        hang_up ()
      in
      hang_up ());
  let client =
    Spindle_client.create ~sw ~net ~mono_clock:(Eio.Stdenv.mono_clock env) ()
  in
  let url = Printf.sprintf "https://127.0.0.1:%d/" port in
  let open_descriptors () = Array.length (Sys.readdir "/dev/fd") in
  let before = open_descriptors () in
  for _ = 1 to 20 do
    match Spindle_client.call client `GET url with
    | Ok _ -> Alcotest.fail "a server speaking no TLS answered"
    | Error _ -> ()
  done;
  check_int "no descriptor left behind" before (open_descriptors ())

(* An address that refuses leaves no socket behind either: the one the
   connection was tried on is closed with the attempt, rather than left on
   the domain's switch for the life of the process -- as an IPv6 address on
   a network with no route for it would leave one for every call. *)
let test_a_refused_address_leaves_no_socket () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    Spindle_client.create ~sw ~net:(Eio.Stdenv.net env)
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ()
  in
  let open_descriptors () = Array.length (Sys.readdir "/dev/fd") in
  let before = open_descriptors () in
  for _ = 1 to 20 do
    match Spindle_client.call client `GET "http://127.0.0.1:1/nobody" with
    | Error (Spindle_client.Unreachable _) -> ()
    | Ok _ | Error (Spindle_client.Timed_out _) ->
        Alcotest.fail "nobody listening is unreachable"
  done;
  check_int "no descriptor left behind" before (open_descriptors ())

(* ------------------------------------------------------------------ *)
(* The edges, over a real socket *)

(* An app on a loopback socket of its own, served as Spindle.Server serves one;
   the port it is on. *)
let serve ~sw ~net ~clock ~domain_mgr ~domains ?(now = fun () -> 0)
    ?trusted_proxies ?proxy_header ?max_body ?send_timeout_s ?max_connections
    served =
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on ~mono_clock:clock ~now ~domain_mgr ~domains
        ?trusted_proxies ?proxy_header ?max_body ?send_timeout_s
        ?max_connections [ socket ] served;
      `Stop_daemon);
  port

(* ---------------------------------------------------------------- *)
(* An event stream, read *)

module Es = Spindle_http.Event_stream

let show_event (e : Es.event) =
  Printf.sprintf "%s[%s]%s%s" e.name e.data
    (match e.id with Some i -> "#" ^ i | None -> "")
    (match e.retry with Some r -> "~" ^ string_of_int r | None -> "")

(* Every event a stream holds, fed to one reader in these pieces. *)
let read_events ?max_event pieces =
  let r = Es.reader ?max_event () in
  let rec each shown = function
    | [] -> String.concat " " (List.rev shown)
    | p :: rest -> (
        match Es.feed r p with
        | Ok events ->
            each (List.rev_append (List.map show_event events) shown) rest
        | Error _ -> String.concat " " (List.rev ("refused" :: shown)))
  in
  each [] pieces

let bytes_of s = List.init (String.length s) (fun i -> String.make 1 s.[i])

(* Each row the HTML standard's "interpreting an event stream" says, and
   what a reader of it owes, whole and a byte at a time. *)
let event_rows =
  [
    ("an event, named", "event: a\ndata: x\n\n", "a[x]");
    ("a name is message unless given", "data: x\n\n", "message[x]");
    ("data lines are joined by breaks", "data: a\ndata: b\n\n", "message[a\nb]");
    ("a comment is passed over", ": ping\ndata: x\n\n", "message[x]");
    ( "one space after the colon is dropped, and only one",
      "data:  x\ndata:y\n\n",
      "message[ x\ny]" );
    ( "a field with no colon is its name, and empty data is data",
      "data\n\n",
      "message[]" );
    ("an event with no data is not dispatched", "event: a\n\n", "");
    ( "an id is kept for the events after it",
      "id: 1\ndata: a\n\ndata: b\n\n",
      "message[a]#1 message[b]#1" );
    ( "an id holding a NUL is passed over",
      "id: a\000b\ndata: x\n\n",
      "message[x]" );
    ( "a retry is digits",
      "retry: 1500\ndata: x\n\nretry: 1x\ndata: y\n\n",
      "message[x]~1500 message[y]~1500" );
    ( "a line ends at CRLF, LF or a lone CR",
      "data: a\r\ndata: b\rdata: c\n\r\n",
      "message[a\nb\nc]" );
    ( "a field it does not know is passed over",
      "extra: 1\ndata: x\n\n",
      "message[x]" );
    ("an event the stream never ended is not dispatched", "data: x\n", "");
    ("a byte-order mark is passed over", "\xef\xbb\xbfdata: x\n\n", "message[x]");
  ]

let test_an_event_stream_reads_as_the_standard_says () =
  List.iter
    (fun (says, stream, owed) ->
      check_string says owed (read_events [ stream ]);
      check_string
        (says ^ ", a byte at a time")
        owed
        (read_events (bytes_of stream)))
    event_rows;
  QCheck.Test.check_exn
    (QCheck.Test.make ~count:500 ~name:"a row, at any cut"
       (QCheck.make
          QCheck.Gen.(
            int_bound (List.length event_rows - 1) >>= fun i ->
            let _, stream, _ = List.nth event_rows i in
            map
              (fun cuts -> (i, cuts))
              (list_size (0 -- 6) (0 -- String.length stream))))
       (fun (i, cuts) ->
         let _, stream, owed = List.nth event_rows i in
         let cuts = List.sort_uniq Int.compare cuts in
         let rec pieces from = function
           | [] -> [ String.sub stream from (String.length stream - from) ]
           | c :: rest when c > from ->
               String.sub stream from (c - from) :: pieces c rest
           | _ :: rest -> pieces from rest
         in
         String.equal (read_events (pieces 0 cuts)) owed));
  let written =
    match Es.event ~name:"state" ~id:"7" "a\nb" with
    | Ok w -> w
    | Error m -> Alcotest.fail m
  in
  check_string "what is written reads back" "state[a\nb]#7"
    (read_events [ written ]);
  Alcotest.(check bool)
    "a name that would end its line is not written" true
    (Result.is_error (Es.event ~name:"a\nb" "x"));
  Alcotest.(check bool)
    "nor an id holding a NUL" true
    (Result.is_error (Es.event ~id:"a\000" "x"));
  check_string "a line that never ends is refused past the limit" "refused"
    (read_events ~max_event:8 [ "data: 0123"; "456789" ]);
  check_string "and so is data held for one event" "refused"
    (read_events ~max_event:8 [ "data: 0123\n"; "data: 4567\n" ]);
  check_string "the limit is each event's, never the stream's"
    "message[0] message[1] message[2]"
    (read_events ~max_event:8 [ "data: 0\n\n"; "data: 1\n\n"; "data: 2\n\n" ])

let test_the_client_reads_as_it_arrives () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let stream =
    Spindle.get
      Spindle.Path.(s "events")
      Spindle.Returns.response
      (let+ last =
         Spindle.Header.optional "last-event-id" Spindle.Codec.string
       in
       Ok
         (Spindle.Response.events (fun send ->
              let ( let* ) = Result.bind in
              let* () =
                send
                  (Printf.sprintf "data: after %s\n\n"
                     (Option.value last ~default:"-"))
              in
              let* () = send "id: 1\ndata: one\n\n" in
              send "id: 2\ndata: two\n\n")))
  and forever =
    Spindle.get
      Spindle.Path.(s "forever")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.events (fun send ->
                 let rec go n =
                   match send (Printf.sprintf "id: %d\ndata: %d\n\n" n n) with
                   | Ok () -> go (n + 1)
                   | Error _ as e -> e
                 in
                 go 1))))
  and slow =
    Spindle.get
      Spindle.Path.(s "slow")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.stream (fun send ->
                 let ( let* ) = Result.bind in
                 let* () = send "first" in
                 (* Nothing more comes, so the reader's wait passes. *)
                 Eio.Fiber.await_cancel ()))))
  in
  let port =
    serve ~sw ~net
      ~clock:(Eio.Stdenv.mono_clock env)
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains:1
      (Spindle.Test.app [ stream; forever; slow; hello ])
  in
  let client =
    Spindle_client.create ~sw ~net ~mono_clock:(Eio.Stdenv.mono_clock env) ()
  in
  let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let seen = ref [] in
  let got =
    Spindle_client.events client ~last_event_id:"0" (url "/events") (fun e ->
        seen := e.data :: !seen;
        `Continue)
  in
  Alcotest.(check (list string))
    "each event, as the server wrote it, Last-Event-ID sent"
    [ "after 0"; "one"; "two" ]
    (List.rev !seen);
  (match got with
  | Ok (Spindle_client.Finished (Some "2")) -> ()
  | _ -> Alcotest.fail "the stream finished at its last id");
  let count = ref 0 in
  (match
     Spindle_client.events client (url "/forever") (fun _ ->
         incr count;
         if !count = 3 then `Stop else `Continue)
   with
  | Ok (Spindle_client.Stopped (Some "3")) -> ()
  | _ -> Alcotest.fail "a stream that never ends stops where the function says");
  (match
     Spindle_client.events client (url "/hello/kim") (fun _ -> `Continue)
   with
  | Ok (Spindle_client.Refused r) ->
      check_int "an answer that is no stream is refused, read whole" 200
        r.status
  | _ -> Alcotest.fail "a JSON answer is no event stream");
  match
    Spindle_client.stream client ~read_timeout_s:0.2 `GET (url "/slow")
      (fun a ->
        let first = Spindle_client.Body.read a.body in
        let second = Spindle_client.Body.read a.body in
        (first, second))
  with
  | Ok (Ok (`Data "first"), Error (Spindle_client.Timed_out _)) -> ()
  | _ ->
      Alcotest.fail
        "each wait is bounded, and the first piece came as it was sent"

let call_on ~net ~clock ~port ?(headers = []) ?body meth path =
  Eio.Switch.run @@ fun sw ->
  let client = Spindle_client.create ~sw ~net ~mono_clock:clock () in
  match
    Spindle_client.call client ~headers ?body meth
      (Printf.sprintf "http://127.0.0.1:%d%s" port path)
  with
  | Ok r -> r
  | Error e -> Alcotest.fail (Spindle_client.error_to_string e)

(* Who the framework says asked, and under which id. *)
let who =
  Spindle.get
    Spindle.Path.(s "who")
    Spindle.Returns.response
    (let+ client = Spindle.client and+ id = Spindle.request_id in
     Ok (Spindle.Response.json Wiretype.(list string) [ client; id ]))

let who_of (r : Spindle_client.response) =
  match Wiretype.decode Wiretype.(list string) r.body with
  | Ok [ client; id ] -> (client, id)
  | _ -> Alcotest.failf "not who: %s" r.body

(* Which domain answered, and how large its minor heap is. *)
let minor_heap =
  Spindle.get
    Spindle.Path.(s "minor-heap")
    Spindle.Returns.response
    (let+ () = Spindle.Dep.return () in
     Ok
       (Spindle.Response.json
          Wiretype.(list int)
          [ (Domain.self () :> int); (Gc.get ()).minor_heap_size ]))

(* The domains the server starts as well as the caller's, since a new
   domain starts at OCaml's default. Asked until a second domain answers. *)
let test_every_serving_domain_raises_its_minor_heap () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
  let port =
    serve ~sw ~net ~clock
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains:2
      (Spindle.Test.app [ minor_heap ])
  in
  let rec ask seen left =
    if left = 0 then Alcotest.fail "one domain answered every request"
    else
      let r = call_on ~net ~clock ~port `GET "/minor-heap" in
      match Wiretype.decode Wiretype.(list int) r.body with
      | Ok [ domain; words ] ->
          if words < 1_048_576 then
            Alcotest.failf "domain %d's minor heap is %d words" domain words;
          let seen = if List.mem domain seen then seen else domain :: seen in
          if List.length seen < 2 then ask seen (left - 1)
      | _ -> Alcotest.failf "not an answer: %s" r.body
  in
  ask [] 200

(* A limit out of range, or a proxy that names nobody, is refused before
   anything is served, and the edge of each range is taken. *)
let test_a_limit_out_of_range_is_refused () =
  Eio_main.run @@ fun env ->
  let serve ?domains ?max_body ?max_header_bytes ?head_timeout_s ?idle_timeout_s
      ?body_timeout_s ?min_body_rate ?send_timeout_s ?discard_limit ?linger_s
      ?body_budget ?trusted_proxies ?max_connections ?drain_s () =
    Eio.Switch.run @@ fun sw ->
    let socket =
      Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:1 ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let stop, stopped = Eio.Promise.create () in
    Eio.Promise.resolve stopped ();
    Spindle.Server.serve_on
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~now:(fun () -> 0)
      ?domains ?max_body ?max_header_bytes ?head_timeout_s ?idle_timeout_s
      ?body_timeout_s ?min_body_rate ?send_timeout_s ?discard_limit ?linger_s
      ?body_budget ?trusted_proxies ?max_connections ?drain_s ~stop [ socket ]
      (Spindle.Test.app [])
  in
  List.iter
    (fun (why, f) ->
      match f () with
      | () -> Alcotest.failf "%s: served" why
      | exception Invalid_argument _ -> ())
    [
      ("no domains", fun () -> serve ~domains:0 ());
      ("no connections", fun () -> serve ~max_connections:0 ());
      ("fewer than none", fun () -> serve ~max_connections:(-1) ());
      ("no rate", fun () -> serve ~min_body_rate:0 ());
      ("no head", fun () -> serve ~max_header_bytes:0 ());
      ("a negative body", fun () -> serve ~max_body:(-1) ());
      ("a negative budget", fun () -> serve ~body_budget:(-1) ());
      ("a negative discard", fun () -> serve ~discard_limit:(-1) ());
      ("no time for a head", fun () -> serve ~head_timeout_s:0. ());
      ("no time idle", fun () -> serve ~idle_timeout_s:(-1.) ());
      ("no time for a body", fun () -> serve ~body_timeout_s:Float.nan ());
      ("forever to send", fun () -> serve ~send_timeout_s:Float.infinity ());
      ("a negative linger", fun () -> serve ~linger_s:(-1.) ());
      ("a negative drain", fun () -> serve ~drain_s:(-0.5) ());
      ( "a range no address has",
        fun () -> serve ~trusted_proxies:[ "10.0.0.0/33" ] () );
      ("an address cut short", fun () -> serve ~trusted_proxies:[ "10.0.0" ] ());
    ];
  serve ~domains:1 ~max_connections:1 ~min_body_rate:1 ~max_header_bytes:1
    ~max_body:0 ~body_budget:0 ~discard_limit:0 ~linger_s:0. ~drain_s:0.
    ~trusted_proxies:[ "10.0.0.0/8"; "::1"; "unix:/run/proxy.sock" ]
    ()

(* A header a client can write is a rate limit a client can step around, so
   X-Forwarded-For and X-Request-Id are believed from a proxy named as
   trusted and from nobody else -- and from that proxy, the address is the
   rightmost one it did not write itself, because anything to the left of it
   is whatever the client sent. *)
(* Behind a proxy that writes Forwarded, the client is read from it, and
   X-Forwarded-For is not; behind one that writes X-Forwarded-For, the
   other way round. A hop that is unknown or hidden ends the walk at the
   peer, and a trusted one is passed over. *)
let test_forwarded_is_believed_where_it_is_named domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let on ?proxy_header trusted_proxies =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      ~trusted_proxies ?proxy_header (Spindle.Test.app [ who ])
  in
  let client port headers =
    fst
      (who_of
         (call_on ~net
            ~clock:(Eio.Stdenv.mono_clock env)
            ~port ~headers `GET "/who"))
  in
  let both =
    [
      ("forwarded", "for=6.6.6.6, for=1.2.3.4"); ("x-forwarded-for", "9.9.9.9");
    ]
  in
  let fwd = on ~proxy_header:Spindle.Server.Forwarded [ "127.0.0.1" ] in
  let xff = on [ "127.0.0.1" ] in
  check_string "Forwarded, where named" "1.2.3.4" (client fwd both);
  check_string "X-Forwarded-For, unless" "9.9.9.9" (client xff both);
  check_string "an unknown hop is the peer" "127.0.0.1"
    (client fwd [ ("forwarded", "for=6.6.6.6, for=unknown") ]);
  check_string "an IPv6 node, unbracketed" "2001:db8::1"
    (client fwd [ ("forwarded", {|for="[2001:db8::1]:4711"|}) ]);
  let fleet =
    on ~proxy_header:Spindle.Server.Forwarded [ "127.0.0.0/8"; "10.0.0.0/8" ]
  in
  check_string "a trusted hop is passed over" "1.2.3.4"
    (client fleet [ ("forwarded", "for=1.2.3.4, for=10.0.0.7") ]);
  let untrusted = on ~proxy_header:Spindle.Server.Forwarded [] in
  check_string "and from nobody else" "127.0.0.1" (client untrusted both)

let test_a_forwarded_address_is_believed_only_from_a_trusted_proxy domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let spoofed =
    [
      ("x-forwarded-for", "6.6.6.6, 1.2.3.4"); ("x-request-id", "the-proxys-id");
    ]
  in
  let open_port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      (Spindle.Test.app [ who ])
  in
  let client, id =
    who_of
      (call_on ~net
         ~clock:(Eio.Stdenv.mono_clock env)
         ~port:open_port ~headers:spoofed `GET "/who")
  in
  check_string "with no proxy trusted, the peer is who asked" "127.0.0.1" client;
  Alcotest.(check bool)
    "and a sent id is not ours" false
    (String.equal id "the-proxys-id");
  let behind =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      ~trusted_proxies:[ "127.0.0.1" ] (Spindle.Test.app [ who ])
  in
  let r =
    call_on ~net
      ~clock:(Eio.Stdenv.mono_clock env)
      ~port:behind ~headers:spoofed `GET "/who"
  in
  let client, id = who_of r in
  check_string "behind a trusted proxy, the address it forwarded for" "1.2.3.4"
    client;
  check_string "and the id it gave" "the-proxys-id" id;
  let client, _ =
    who_of
      (call_on ~net
         ~clock:(Eio.Stdenv.mono_clock env)
         ~port:behind
         ~headers:
           [ ("x-forwarded-for", "6.6.6.6"); ("x-forwarded-for", "1.2.3.4") ]
         `GET "/who")
  in
  check_string "the proxy's own line, not the client's before it" "1.2.3.4"
    client;
  let fleet =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      ~trusted_proxies:[ "127.0.0.0/8"; "10.0.0.0/8" ]
      (Spindle.Test.app [ who ])
  in
  let client, id =
    who_of
      (call_on ~net
         ~clock:(Eio.Stdenv.mono_clock env)
         ~port:fleet
         ~headers:
           [
             ("x-forwarded-for", "6.6.6.6, 1.2.3.4, 10.0.0.7");
             ("x-request-id", "the-proxys-id");
           ]
         `GET "/who")
  in
  check_string "a proxy in a trusted range, past a hop in another" "1.2.3.4"
    client;
  check_string "and its id" "the-proxys-id" id;
  check_header "answered with it" (Some "the-proxys-id")
    (List.assoc_opt "x-request-id" r.headers);
  let _, id =
    who_of
      (call_on ~net
         ~clock:(Eio.Stdenv.mono_clock env)
         ~port:behind
         ~headers:[ ("x-request-id", "not an id; really") ]
         `GET "/who")
  in
  Alcotest.(check bool)
    "an id nobody could mean is replaced" false
    (String.equal id "not an id; really")

let test_a_body_past_the_limit_is_413 domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      ~max_body:32
      (Spindle.Test.app [ echo ])
  in
  let r =
    call_on ~net
      ~clock:(Eio.Stdenv.mono_clock env)
      ~port
      ~headers:[ ("content-type", "application/json") ]
      ~body:(Printf.sprintf {|{"name":"%s"}|} (String.make 200 'a'))
      `POST "/echo"
  in
  check_int "too large" 413 r.status;
  check_string "said as a sentence"
    {|{"error":"too_large","message":"That request is too large."}|} r.body;
  let r =
    call_on ~net
      ~clock:(Eio.Stdenv.mono_clock env)
      ~port
      ~headers:[ ("content-type", "application/json") ]
      ~body:{|{"name":"lee"}|} `POST "/echo"
  in
  check_int "and one within it is read" 201 r.status

(* HEAD is GET's head: the same content-length, and no body after it. A
   HEAD that says 0 tells a cache or a download manager the page is empty. *)
let test_head_says_how_long_get_would_be domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      (Spindle.Test.app [ hello ])
  in
  let got =
    call_on ~net ~clock:(Eio.Stdenv.mono_clock env) ~port `GET "/hello/kim"
  in
  let raw =
    Eio.Switch.run (fun inner ->
        let flow =
          Eio.Net.connect ~sw:inner net
            (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
        in
        Eio.Flow.copy_string
          "HEAD /hello/kim HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
          flow;
        Eio.Buf_read.(parse_exn take_all) flow ~max_size:65536)
  in
  let length =
    String.split_on_char '\n' raw
    |> List.find_map (fun line ->
        match String.index_opt line ':' with
        | Some i
          when String.equal
                 (String.lowercase_ascii (String.sub line 0 i))
                 "content-length" ->
            Some
              (String.trim
                 (String.sub line (i + 1) (String.length line - i - 1)))
        | Some _ | None -> None)
  in
  Alcotest.(check (option string))
    "GET's length"
    (Some (string_of_int (String.length got.body)))
    length;
  Alcotest.(check bool)
    "and nothing after the head" true
    (String.ends_with ~suffix:"\r\n\r\n" raw)

(* An answer a middleware gave by itself is still a request the server
   answered, and the access log says so. *)
let test_a_middleware_answer_is_in_the_access_log domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let closed _handler _req =
    Spindle.Response.refusal
      (Spindle.Refusal.make
         (code "closed" `Service_unavailable)
         "We are closed for a moment.")
  in
  let port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      (Spindle.Test.app ~middleware:[ closed ] [ hello ])
  in
  let r =
    call_on ~net ~clock:(Eio.Stdenv.mono_clock env) ~port `GET "/hello/kim"
  in
  check_int "its own answer" 503 r.status;
  Alcotest.(check bool)
    "one access line for it" true
    (List.exists (contains ~sub:{|"message":"GET /hello/kim 503"|}) !lines)

(* The access line is what went out: an answer the server would not write
   is its 500, and a HEAD sent no bytes. The HEAD goes on a socket of its
   own, since the client waits for the body a HEAD's length names. *)
let test_the_access_log_says_what_went_out domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let framed =
    Spindle.get
      Spindle.Path.(s "framed")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok (Spindle.Response.make ~headers:[ ("content-length", "0") ] "x")))
  in
  let port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      (Spindle.Test.app [ framed; hello ])
  in
  let call = call_on ~net ~clock:(Eio.Stdenv.mono_clock env) ~port in
  check_int "refused on the way out" 500 (call `GET "/framed").status;
  Eio.Switch.run (fun inner ->
      let flow =
        Eio.Net.connect ~sw:inner net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      Eio.Flow.copy_string
        "HEAD /hello/kim HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n" flow;
      ignore (Eio.Buf_read.(parse_exn take_all) flow ~max_size:65536 : string));
  let logged sub = List.exists (contains ~sub) !lines in
  Alcotest.(check bool)
    "the 500 is logged, not the handler's 200" true
    (logged {|"message":"GET /framed 500"|});
  Alcotest.(check bool)
    "with the refusal it went out as" true
    (logged {|"spindle.refusal.code":"internal"|});
  Alcotest.(check bool)
    "and the HEAD with no bytes" true
    (List.exists
       (fun l ->
         contains ~sub:{|"message":"HEAD /hello/kim 200"|} l
         && contains ~sub:{|"http.response.body.size":0|} l)
       !lines)

(* An IPv4 client reached through the IPv6 wildcard is its IPv4 address, so
   a proxy named by one is trusted through the other. *)
let test_an_ipv4_peer_through_the_ipv6_wildcard domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V6.any, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~now:(fun () -> 0)
        ~trusted_proxies:[ "127.0.0.1" ] [ socket ] (Spindle.Test.app [ who ]);
      `Stop_daemon);
  let client, _ =
    who_of
      (call_on ~net
         ~clock:(Eio.Stdenv.mono_clock env)
         ~port
         ~headers:[ ("x-forwarded-for", "1.2.3.4") ]
         `GET "/who")
  in
  check_string "trusted as 127.0.0.1" "1.2.3.4" client

(* A port nothing holds, for a test that runs the server itself. *)
let free_port ~net =
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen net ~sw ~backlog:1 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  match Eio.Net.listening_addr socket with
  | `Tcp (_, p) -> p
  | _ -> Alcotest.fail "expected a TCP socket"

(* Work nobody is waiting for: a raise is logged and never fails the switch
   it runs on, and a cancellation is the switch going away, not a failure
   to log. *)
exception Background_bug

let test_a_background_raise_is_logged_not_raised () =
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  Eio_main.run @@ fun _env ->
  Eio.Switch.run (fun sw ->
      let background = Spindle.Background.create ~sw in
      Spindle.Background.fork background ~what:"a job that fails" (fun () ->
          raise Background_bug);
      Spindle.Background.fork background ~what:"a job that waits" (fun () ->
          Eio.Fiber.await_cancel ());
      Eio.Fiber.yield ());
  Alcotest.(check bool)
    "the raise, logged" true
    (List.exists (contains ~sub:"a job that fails") !lines);
  Alcotest.(check bool)
    "with what it was and where" true
    (List.exists
       (fun l ->
         contains ~sub:{|Background_bug"|} l
         && contains ~sub:{|"error.stack":"|} l)
       !lines);
  Alcotest.(check bool)
    "and the cancellation, not" false
    (List.exists (contains ~sub:"a job that waits") !lines)

(* The first SIGTERM resolves the promise a server stops on. *)
let test_a_signal_stops_the_server () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let stop = Spindle.Server.stop_on_signals ~sw () in
  Unix.kill (Unix.getpid ()) Sys.sigterm;
  Eio.Promise.await stop

(* An app served on [In_memory]'s virtual time, and the way to connect to
   it. *)
let serve_in_memory ~sw env ?domains ?send_timeout_s ?max_connections served =
  let listening, connect = In_memory.listen () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~now:(fun () -> 0)
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ?domains ?send_timeout_s ?max_connections [ listening ] served;
      `Stop_daemon);
  connect

let seconds_between a b = Mtime.Span.to_float_ns (Mtime.span a b) /. 1e9

(* A drain that runs out does not wait for the answer still being made: the
   server returns as the drain ends, and says how many it left. *)
let test_a_drain_that_runs_out_ends_on_time domains () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.mono_clock env in
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let started, begun = Eio.Promise.create () in
  let never =
    Spindle.get
      Spindle.Path.(s "never")
      Spindle.Returns.response
      (Spindle.Dep.of_request (fun _ ->
           Eio.Promise.resolve begun ();
           Eio.Fiber.await_cancel ()))
  in
  let drain_s = 0.2 in
  let stop, stopping = Eio.Promise.create () in
  let returned, return = Eio.Promise.create () in
  let listening, connect = In_memory.listen () in
  Eio.Fiber.fork ~sw (fun () ->
      Spindle.Server.serve_on ~mono_clock:clock
        ~now:(fun () -> 0)
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains ~stop ~drain_s [ listening ]
        (Spindle.Test.app [ never ]);
      Eio.Promise.resolve return (Eio.Time.Mono.now clock));
  Eio.Switch.run @@ fun inner ->
  let flow = connect ~sw:inner in
  Eio.Flow.copy_string "GET /never HTTP/1.1\r\nHost: t\r\n\r\n" flow;
  Eio.Promise.await started;
  let stopped_at = Eio.Time.Mono.now clock in
  Eio.Promise.resolve stopping ();
  Alcotest.(check (float 1e-6))
    "returned as the drain ended" drain_s
    (seconds_between stopped_at (Eio.Promise.await returned));
  Alcotest.(check bool)
    "saying what it left" true
    (List.exists (contains ~sub:"1 requests unanswered") !lines)

(* Stopping lets the answer being written finish, ends the stream that
   would never end by itself, and returns as soon as both have, well inside
   the drain. *)
let test_a_stop_lets_answers_finish domains () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.mono_clock env in
  let hub : (unit, string) Spindle.Broadcast.t = Spindle.Broadcast.create () in
  let answering_s = 0.3 and stop_after_s = 0.1 in
  let slow =
    Spindle.get
      Spindle.Path.(s "slow")
      Spindle.Returns.response
      (Spindle.Dep.of_request (fun _ ->
           Eio.Time.Mono.sleep clock answering_s;
           Ok (Ok (Spindle.Response.json Wiretype.string "done"))))
  in
  let events =
    Spindle.get
      Spindle.Path.(s "events")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.events (fun send ->
                 let ( let* ) = Result.bind in
                 let sub = Spindle.Broadcast.subscribe hub ~topic:"t" () in
                 let* () = send ": open\n\n" in
                 let rec loop () =
                   match Spindle.Broadcast.next sub with
                   | Some e ->
                       let* () = send e in
                       loop ()
                   | None -> Ok ()
                 in
                 loop ()))))
  in
  let stop, stopping = Eio.Promise.create () in
  let returned, return = Eio.Promise.create () in
  let listening, connect = In_memory.listen () in
  let started = Eio.Time.Mono.now clock in
  Eio.Fiber.fork ~sw (fun () ->
      Spindle.Server.serve_on ~mono_clock:clock
        ~now:(fun () -> 0)
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains ~stop ~drain_s:2.0
        ~on_stop:(fun () -> Spindle.Broadcast.close hub)
        [ listening ]
        (Spindle.Test.app [ slow; events ]);
      Eio.Promise.resolve return (Eio.Time.Mono.now clock));
  let read_all request =
    Eio.Switch.run @@ fun inner ->
    let flow = connect ~sw:inner in
    Eio.Flow.copy_string request flow;
    Eio.Buf_read.(parse_exn take_all) flow ~max_size:65536
  in
  let stream = ref "" and answer = ref "" in
  Eio.Fiber.all
    [
      (fun () -> stream := read_all "GET /events HTTP/1.1\r\nHost: t\r\n\r\n");
      (fun () ->
        answer :=
          read_all "GET /slow HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
      (fun () ->
        Eio.Time.Mono.sleep clock stop_after_s;
        Eio.Promise.resolve stopping ());
    ];
  Alcotest.(check bool)
    "the answer being written finished" true
    (String.starts_with ~prefix:"HTTP/1.1 200" !answer);
  Alcotest.(check bool) "whole" true (contains ~sub:{|"done"|} !answer);
  Alcotest.(check bool)
    "the stream ended cleanly, with its last chunk" true
    (String.ends_with ~suffix:"\r\n0\r\n\r\n" !stream);
  Alcotest.(check (float 1e-6))
    "and it returned as the answer finished" answering_s
    (seconds_between started (Eio.Promise.await returned))

(* Past its cap the server accepts nothing more, and serves the next
   connection once one closes: until then it waits to be accepted. *)
let test_past_the_cap_a_connection_waits domains () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let connect =
    serve_in_memory ~sw env ~domains ~max_connections:1
      (Spindle.Test.app [ hello ])
  in
  let status flow =
    Eio.Buf_read.line (Eio.Buf_read.of_flow flow ~max_size:4096)
  in
  Eio.Switch.run @@ fun inner ->
  let first = connect ~sw:inner in
  Eio.Flow.copy_string "GET /hello/a HTTP/1.1\r\nHost: t\r\n\r\n" first;
  check_string "the first is served" "HTTP/1.1 200 OK" (status first);
  let second = connect ~sw:inner in
  Eio.Flow.copy_string
    "GET /hello/b HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n" second;
  (* A second of virtual time, inside every limit that could close the
     first: nothing but the cap holds the second back. *)
  Alcotest.(check bool)
    "the second waits while the first is held" true
    (Eio.Fiber.first
       (fun () ->
         ignore (status second : string);
         false)
       (fun () ->
         Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 1.0;
         true));
  Eio.Flow.close first;
  check_string "and is served once it closes" "HTTP/1.1 200 OK" (status second)

(* Whether [addr] on [port] answers a request: nobody listening there is a
   refusal, at once. *)
let answers ~net addr port =
  match
    Eio.Switch.run @@ fun inner ->
    let flow = Eio.Net.connect ~sw:inner net (`Tcp (addr, port)) in
    Eio.Flow.copy_string
      "GET /hello/a HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n" flow;
    contains ~sub:" 200 "
      (Eio.Buf_read.(parse_exn take_all) flow ~max_size:65536)
  with
  | answered -> answered
  | exception (Eio.Io _ | End_of_file) -> false

let served_on ~sw ~net ~env ~domains host =
  let port = free_port ~net in
  let told, tell = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.run ~sw ~net
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~now:(fun () -> 0)
        ~port ?host
        ~ready:(fun where -> Eio.Promise.resolve tell where)
        (Spindle.Test.app [ hello ]);
      `Stop_daemon);
  (port, Eio.Promise.await told)

(* Nothing named is both loopback addresses, whatever the resolver would
   have said about localhost. *)
let test_localhost_is_both_loopbacks domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port, where = served_on ~sw ~net ~env ~domains None in
  check_string "says which" "127.0.0.1 and [::1]" where;
  Alcotest.(check bool)
    "IPv4" true
    (answers ~net Eio.Net.Ipaddr.V4.loopback port);
  Alcotest.(check bool)
    "IPv6" true
    (answers ~net Eio.Net.Ipaddr.V6.loopback port)

(* Every interface, of both families, whichever wildcard is written: the
   IPv6 one answers IPv4 too on a host where it takes it, and the IPv4 one
   beside it where not -- either way both loopback addresses are served,
   since they are interfaces like any other. *)
let test_a_wildcard_listens_on_every_interface domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  List.iter
    (fun host ->
      let port, where = served_on ~sw ~net ~env ~domains (Some host) in
      Alcotest.(check bool)
        (host ^ " says so: " ^ where)
        true
        (contains ~sub:"every interface" where);
      Alcotest.(check bool)
        (host ^ ", IPv4") true
        (answers ~net Eio.Net.Ipaddr.V4.loopback port);
      Alcotest.(check bool)
        (host ^ ", IPv6") true
        (answers ~net Eio.Net.Ipaddr.V6.loopback port))
    [ "0.0.0.0"; "::" ]

(* An address is exactly what is listened on. *)
let test_an_address_is_exactly_that_one domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port, where = served_on ~sw ~net ~env ~domains (Some "127.0.0.1") in
  check_string "says which" "127.0.0.1" where;
  Alcotest.(check bool)
    "the one named" true
    (answers ~net Eio.Net.Ipaddr.V4.loopback port);
  Alcotest.(check bool)
    "and not the other" false
    (answers ~net Eio.Net.Ipaddr.V6.loopback port)

(* The first line the log says holding [sub]: the server says how a
   connection ended after its client has read all it will. *)
let logged sub =
  let said, say = Eio.Promise.create () in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l ->
      if contains ~sub l then ignore (Eio.Promise.try_resolve say l : bool))
    ();
  said

(* The commonest way a stream ends: the browser went. The write notices
   first, the producer is told at its send rather than cancelled, and the
   stream's own line says so -- not that the server is stopping, nor that
   the connection closed under it, which is a handler stopped wherever it
   stood. *)
let test_a_stream_ends_when_its_client_goes domains () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let ended = logged "ended: client gone" in
  let ticks =
    Spindle.get
      Spindle.Path.(s "ticks")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.events (fun send ->
                 let rec go () = Result.bind (send "data: tick\n\n") go in
                 go ()))))
  in
  let connect = serve_in_memory ~sw env ~domains (Spindle.Test.app [ ticks ]) in
  Eio.Switch.run (fun inner ->
      let flow = connect ~sw:inner in
      Eio.Flow.copy_string "GET /ticks HTTP/1.1\r\nHost: t\r\n\r\n" flow;
      ignore (Eio.Flow.single_read flow (Cstruct.create 256) : int));
  ignore (Eio.Promise.await ended : string)

(* A client that asks and never reads. Past the send limit the server gives
   up on it, so its connection slot is somebody else's -- here the only
   slot there is. The answer is larger than a connection holds, so the
   write cannot finish unread. *)
let test_a_client_that_never_reads_frees_its_slot domains () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let big =
    Spindle.get
      Spindle.Path.(s "big")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok (Spindle.Response.make (String.make (1024 * 1024) 'x'))))
  in
  let connect =
    serve_in_memory ~sw env ~domains ~send_timeout_s:0.3 ~max_connections:1
      (Spindle.Test.app [ big; hello ])
  in
  Eio.Switch.run @@ fun inner ->
  let stuck = connect ~sw:inner in
  Eio.Flow.copy_string "GET /big HTTP/1.1\r\nHost: t\r\n\r\n" stuck;
  let second = connect ~sw:inner in
  Eio.Flow.copy_string
    "GET /hello/b HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n" second;
  check_string "the slot came free, and the next is served" "HTTP/1.1 200 OK"
    (Eio.Buf_read.line (Eio.Buf_read.of_flow second ~max_size:4096))

(* The send limit bounds a write that stops, not one that takes long: a
   client taking the answer a piece at a time, each pause inside the limit,
   gets all of it however long the whole takes; one that stops taking is
   cut off once the limit and a tick have passed. *)
let test_the_send_limit_is_on_a_stop_not_a_length domains () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.mono_clock env in
  let limit = 0.3 and size = 1024 * 1024 in
  let big =
    Spindle.get
      Spindle.Path.(s "big")
      Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.make (String.make size 'x'))))
  in
  let connect =
    serve_in_memory ~sw env ~domains ~send_timeout_s:limit
      (Spindle.Test.app [ big ])
  in
  let buf = Cstruct.create 65536 in
  let rec read_pausing flow total =
    match Eio.Flow.single_read flow buf with
    | n ->
        Eio.Time.Mono.sleep clock (limit *. 2. /. 3.);
        read_pausing flow (total + n)
    | exception End_of_file -> total
  in
  let started = Eio.Time.Mono.now clock in
  let slowly =
    Eio.Switch.run @@ fun inner ->
    let flow = connect ~sw:inner in
    Eio.Flow.copy_string
      "GET /big HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n" flow;
    read_pausing flow 0
  in
  Alcotest.(check bool) "all of it arrived" true (slowly > size);
  Alcotest.(check bool)
    "over many times the limit" true
    (seconds_between started (Eio.Time.Mono.now clock) > 10. *. limit);
  let stopped =
    Eio.Switch.run @@ fun inner ->
    let flow = connect ~sw:inner in
    Eio.Flow.copy_string
      "GET /big HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n" flow;
    let first = Eio.Flow.single_read flow buf in
    Eio.Time.Mono.sleep clock (limit *. 1.2);
    first
    + String.length
        (Eio.Buf_read.(parse_exn take_all) flow ~max_size:(2 * size))
  in
  Alcotest.(check bool) "a client that stopped is cut off" true (stopped < size)

(* A stream whose client stopped reading: dropping it from a broadcast
   cannot end it, because its fiber waits in the write, so the send limit
   does -- and the stream's own line says why. *)
let test_a_stream_ends_when_its_client_stops_reading domains () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let ended = logged "ended: client stopped reading" in
  let chunk = "data: " ^ String.make 65536 'x' ^ "\n\n" in
  let flood =
    Spindle.get
      Spindle.Path.(s "flood")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.events (fun send ->
                 let rec go () = Result.bind (send chunk) go in
                 go ()))))
  in
  let connect =
    serve_in_memory ~sw env ~domains ~send_timeout_s:0.3
      (Spindle.Test.app [ flood ])
  in
  Eio.Switch.run @@ fun inner ->
  let flow = connect ~sw:inner in
  Eio.Flow.copy_string "GET /flood HTTP/1.1\r\nHost: t\r\n\r\n" flow;
  ignore (Eio.Promise.await ended : string)

(* The application's clock jumps an hour on every reading, and what the
   access log says a request took is still what it took: a duration is the
   monotonic clock's to measure. *)
let test_a_jumping_clock_moves_no_duration domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let hour = ref 0 in
  let now () =
    hour := !hour + 3_600_000;
    !hour
  in
  let port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      ~now
      (Spindle.Test.app [ hello ])
  in
  let r =
    call_on ~net ~clock:(Eio.Stdenv.mono_clock env) ~port `GET "/hello/kim"
  in
  check_int "answered" 200 r.status;
  let ns =
    List.find_map
      (fun l ->
        match Yojson.Safe.from_string l with
        | `Assoc fields when List.mem_assoc "http.response.status_code" fields
          -> (
            match List.assoc_opt "duration" fields with
            | Some (`Int ns) -> Some ns
            | _ -> None)
        | _ -> None)
      !lines
  in
  match ns with
  | Some ns ->
      Alcotest.(check bool)
        (Printf.sprintf "%d ns is the time it took" ns)
        true (ns < 5_000_000_000)
  | None -> Alcotest.fail "no access line"

(* An https URL is spoken TLS or not at all. Against a server that answers
   plain HTTP, the handshake fails -- and the call must fail with it, never
   come back as an answer read in the clear. *)
let test_https_is_never_spoken_as_plain_http domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains
      ~clock:(Eio.Stdenv.mono_clock env)
      (Spindle.Test.app [ hello ])
  in
  let client =
    Spindle_client.create ~sw ~net
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~timeout_s:2. ()
  in
  match
    Spindle_client.call client `GET
      (Printf.sprintf "https://127.0.0.1:%d/hello/kim" port)
  with
  | Error (Spindle_client.Unreachable _ | Spindle_client.Timed_out _) -> ()
  | Ok _ -> Alcotest.fail "an https call was answered in the clear"

(* The framework logs no header value and no query string: a request's
   credentials -- a bearer token, a cookie, a code in the query -- reach no
   line at any level, the access line included. *)
let test_no_header_value_reaches_the_log () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Debug)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains:1 ~clock
      (Spindle.Test.app [ hello ])
  in
  let client = Spindle_client.create ~sw ~net ~mono_clock:clock () in
  (match
     Spindle_client.call client `GET
       ~headers:
         [
           ("authorization", "Bearer s3cret-token");
           ("cookie", "session=s3cret-cookie");
         ]
       (Printf.sprintf "http://127.0.0.1:%d/hello/kim?code=s3cret-query" port)
   with
  | Ok r -> check_int "answered" 200 r.status
  | Error e -> Alcotest.fail (Spindle_client.error_to_string e));
  Alcotest.(check bool) "the request was logged" true (!lines <> []);
  List.iter
    (fun secret ->
      Alcotest.(check bool)
        (secret ^ " is in no line")
        false
        (List.exists (contains ~sub:secret) !lines))
    [ "s3cret-token"; "s3cret-cookie"; "s3cret-query" ]

(* A request id is made from a random state per domain, seeded per domain:
   two hundred requests over four domains, each on a connection of its own
   so any domain may take it, are two hundred ids. *)
let test_request_ids_are_distinct_across_domains () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
  let port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains:4 ~clock
      (Spindle.Test.app [ hello ])
  in
  let client =
    Spindle_client.create ~sw ~net ~mono_clock:clock ~timeout_s:5. ()
  in
  let url = Printf.sprintf "http://127.0.0.1:%d/hello/kim" port in
  let ids =
    List.init 200 (fun _ ->
        match
          Spindle_client.call client `GET
            ~headers:[ ("connection", "close") ]
            url
        with
        | Ok r ->
            Option.value
              (List.assoc_opt "x-request-id" r.headers)
              ~default:"none"
        | Error e -> Alcotest.fail (Spindle_client.error_to_string e))
  in
  check_int "no two alike" 200 (List.length (List.sort_uniq String.compare ids))

(* Which domains answered, asked one connection at a time until [expect]
   of them have. Every domain the server runs has an accept waiting on the
   socket while it answers, so the kernel's choice of which completes
   decides only how many requests it takes, never which domains answer: a
   domain that never accepts is one the loop never sees, and it asks for
   ever. The server is on domains of its own: one that also ran the client
   would be busy making each connection as it arrived. *)
let domains_answering env ?domains ?(also = ignore) ~expect () =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let seen = Atomic.make [] in
  let rec note d =
    let before = Atomic.get seen in
    if not (Atomic.compare_and_set seen before (d :: before)) then note d
  in
  let where =
    Spindle.get
      Spindle.Path.(s "where")
      Spindle.Returns.response
      (Spindle.Dep.of_request (fun _ ->
           note (Domain.self () :> int);
           also ();
           Ok (Ok (Spindle.Response.make "here"))))
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:256 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Domain_manager.run domain_mgr (fun () ->
          Spindle.Server.serve_on
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~now:(fun () -> 0)
            ~domain_mgr ?domains [ socket ]
            (Spindle.Test.app [ where ]));
      `Stop_daemon);
  let answered () = List.sort_uniq Int.compare (Atomic.get seen) in
  let rec ask () =
    if List.length (answered ()) < expect then begin
      Eio.Switch.run (fun inner ->
          let flow =
            Eio.Net.connect ~sw:inner net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
          in
          Eio.Flow.copy_string
            "GET /where HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n" flow;
          Alcotest.(check bool)
            "answered" true
            (String.starts_with ~prefix:"HTTP/1.1 200"
               (Eio.Buf_read.(parse_exn take_all) flow ~max_size:65536)));
      ask ()
    end
  in
  ask ();
  answered ()

(* A server answers on the domains it was given, and on no others. *)
let test_a_server_answers_on_every_domain_it_was_given () =
  Eio_main.run @@ fun env ->
  check_int "four domains answered" 4
    (List.length (domains_answering env ~domains:4 ~expect:4 ()))

(* Unasked, a server is on every core the machine recommends. *)
let test_every_core_unasked () =
  Eio_main.run @@ fun env ->
  let n = Domain.recommended_domain_count () in
  check_int "as many as the machine recommends" n
    (List.length (domains_answering env ~expect:n ()))

(* Work a request forks runs on the request's own domain, from every
   domain, and a raise in it is logged under the request; work forked from a
   domain Spindle does not run is posted to the domain that made the
   Background, and runs there. *)
let test_work_runs_where_it_was_caused () =
  let lines = ref [] and lock = Mutex.create () in
  let failed = Atomic.make 0 and logged = Eio.Condition.create () in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Info)
    ~out:(fun l ->
      Mutex.protect lock (fun () -> lines := l :: !lines);
      if contains ~sub:"a job that fails" l then begin
        Atomic.incr failed;
        Eio.Condition.broadcast logged
      end)
    ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let background = Spindle.Background.create ~sw in
  let asked = Atomic.make 0 and ran = Atomic.make [] in
  let rec note pair =
    let before = Atomic.get ran in
    if not (Atomic.compare_and_set ran before (pair :: before)) then note pair
  in
  let also () =
    let here = (Domain.self () :> int) in
    Atomic.incr asked;
    Spindle.Background.fork background ~what:"a job that fails" (fun () ->
        note (here, (Domain.self () :> int));
        raise Background_bug)
  in
  let answered = domains_answering env ~domains:4 ~also ~expect:4 () in
  check_int "asked from four domains" 4 (List.length answered);
  (* A job's raise is logged after it ran, so once every raise is, every
     job has run. *)
  Eio.Condition.loop_no_mutex logged (fun () ->
      if Atomic.get failed >= Atomic.get asked then Some () else None);
  check_int "every job ran" (Atomic.get asked) (List.length (Atomic.get ran));
  Alcotest.(check bool)
    "each on the domain that asked" true
    (List.for_all (fun (a, r) -> a = r) (Atomic.get ran));
  Alcotest.(check bool)
    "its raise logged under the request" true
    (List.exists
       (fun l ->
         contains ~sub:"a job that fails" l
         && contains ~sub:{|"request_id":"|} l)
       !lines);
  let posted, post = Eio.Promise.create () in
  Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
      Spindle.Background.fork background ~what:"posted" (fun () ->
          Eio.Promise.resolve post (Domain.self () :> int)));
  check_int "posted, it ran where the Background was made"
    (Domain.self () :> int)
    (Eio.Promise.await posted)

(* The systhread a blocking call runs on still logs under its request, and
   an Eio effect there -- a mistake the type cannot catch -- is a raise and
   never a hang. *)
let test_blocking_carries_the_request_and_refuses_an_effect () =
  Eio_main.run @@ fun _env ->
  Alcotest.(check (option string))
    "the request's id, on the thread" (Some "r1")
    (Spindle.Log.with_request_id "r1" (fun () ->
         Spindle.blocking Spindle.Log.request_id));
  match Spindle.blocking (fun () -> Eio.Fiber.yield ()) with
  | () -> Alcotest.fail "an effect on a systhread did something"
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception _ -> ()

let test_a_pretty_line_reads () =
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Pretty ~level:(Some Logs.Info)
    ~out:(fun l -> lines := l :: !lines)
    ();
  L.info (fun m ->
      m "moved %s" "d4" ~tags:(Spindle.Log.tags [ ("status", `Int 202) ]));
  match !lines with
  | [ line ] ->
      List.iter
        (fun sub -> Alcotest.(check bool) sub true (contains ~sub line))
        [ "info"; "test.web"; "moved d4"; "status=202" ];
      Alcotest.(check bool) "and not JSON" false (contains ~sub:"{" line)
  | l -> Alcotest.failf "expected one line, got %d" (List.length l)

(* What a route answers with, for the tests that only ask which answered. *)
let says word = Spindle.Dep.return (Ok (Spindle.Response.make word))
let user_id = Spindle.Path.str "user_id"

(* A literal beats a parameter wherever the routes are listed, so /users/me
   is never read as somebody called "me". *)
let test_a_literal_beats_a_parameter_in_any_order () =
  let me =
    Spindle.get
      Spindle.Path.(s "users" / s "me")
      Spindle.Returns.response (says "me")
  in
  let user =
    Spindle.get
      Spindle.Path.(s "users" / user_id)
      Spindle.Returns.response
      (let+ id = Spindle.param user_id in
       Ok (Spindle.Response.make id))
  in
  List.iter
    (fun (order, routes) ->
      let a = Spindle.Test.app routes in
      check_string (order ^ ": the literal") "me"
        (Spindle.Test.call a `GET "/users/me").body;
      check_string
        (order ^ ": the parameter")
        "kim" (Spindle.Test.call a `GET "/users/kim").body)
    [ ("literal first", [ me; user ]); ("parameter first", [ user; me ]) ]

(* Two routes that differ only by a parameter's type: the one that may
   decline is asked first, and declines what it cannot read. *)
let test_a_parameter_that_declines_is_asked_first () =
  let by_number =
    Spindle.get
      Spindle.Path.(s "items" / Spindle.Path.int ~or_not_found:() "number")
      Spindle.Returns.response (says "number")
  in
  let by_name =
    Spindle.get
      Spindle.Path.(s "items" / Spindle.Path.str "name")
      Spindle.Returns.response (says "name")
  in
  List.iter
    (fun routes ->
      let a = Spindle.Test.app routes in
      check_string "a number" "number"
        (Spindle.Test.call a `GET "/items/5").body;
      check_string "a name" "name" (Spindle.Test.call a `GET "/items/pen").body)
    [ [ by_number; by_name ]; [ by_name; by_number ] ]

let refused routes =
  match Spindle.App.make routes with
  | Ok _ -> Alcotest.fail "the app was made"
  | Error m -> m

let test_routes_that_could_both_answer_are_refused () =
  let m =
    refused
      [
        Spindle.get
          Spindle.Path.(s "users" / user_id)
          Spindle.Returns.response (says "id");
        Spindle.get
          Spindle.Path.(s "users" / Spindle.Path.str "name")
          Spindle.Returns.response (says "name");
      ]
  in
  List.iter
    (fun sub -> Alcotest.(check bool) sub true (contains ~sub m))
    [ "GET /users/{user_id}"; "GET /users/{name}" ];
  (* Under two methods, one URL is two routes. *)
  ignore
    (Spindle.Test.app
       [
         Spindle.get
           Spindle.Path.(s "users" / user_id)
           Spindle.Returns.response (says "read");
         Spindle.delete
           Spindle.Path.(s "users" / user_id)
           Spindle.Returns.response (says "gone");
       ])

let order_id = Spindle.Path.int "order_id"

let test_a_parameter_its_path_lacks_is_refused () =
  let m =
    refused
      [
        Spindle.get
          Spindle.Path.(s "orders")
          Spindle.Returns.response
          (let+ id = Spindle.param order_id in
           Ok (Spindle.Response.make (string_of_int id)));
      ]
  in
  List.iter
    (fun sub -> Alcotest.(check bool) sub true (contains ~sub m))
    [ "GET /orders"; "order_id" ];
  Alcotest.(check bool)
    "a literal no URL can match" true
    (contains ~sub:"a/b"
       (refused
          [
            Spindle.get
              Spindle.Path.(s "a/b")
              Spindle.Returns.response (says "");
          ]));
  Alcotest.(check bool)
    "one parameter twice" true
    (contains ~sub:"twice"
       (refused
          [
            Spindle.get
              Spindle.Path.(order_id / order_id)
              Spindle.Returns.response (says "");
          ]))

(* The check cannot see through a bind, which says nothing of what it reads;
   what it hides is our bug when it runs, and a 500 that says nothing. *)
let test_a_parameter_behind_a_bind_is_found_when_it_runs () =
  let a =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(s "orders")
          Spindle.Returns.response
          (Spindle.Dep.bind Spindle.now (fun _ ->
               let+ id = Spindle.param order_id in
               Ok (Spindle.Response.make (string_of_int id))));
      ]
  in
  check_status "our bug" 500 (Spindle.Test.call a `GET "/orders").status

let order =
  Spindle.get
    Spindle.Path.(s "orders" / order_id)
    Spindle.Returns.response
    (let+ id = Spindle.param order_id in
     Ok (Spindle.Response.json Wiretype.int id))

(* The literals chose the route, so a parameter that does not parse is the
   client's input, said at its place -- not a URL nobody serves. *)
let test_a_bad_parameter_is_a_problem () =
  let a = Spindle.Test.app [ order ] in
  check_string "a number" "7" (Spindle.Test.call a `GET "/orders/7").body;
  List.iter
    (fun target ->
      let r = Spindle.Test.call a `GET target in
      check_status target 400 r.status;
      check_string target
        {|{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"path.order_id","code":"malformed","message":"This is not a whole number."}]}|}
        r.body)
    [ "/orders/abc"; "/orders/0x1f"; "/orders/1_000"; "/orders/%2B3" ];
  check_status "an empty segment is no parameter" 404
    (Spindle.Test.call a `GET "/orders/").status

(* A segment of the application's own type: refused as a problem, or --
   asked for -- a URL this route does not answer. *)
let test_a_custom_segment_is_a_problem_or_not_the_route () =
  let even ?or_not_found () =
    Spindle.Path.param ?or_not_found "n"
      (Spindle.Codec.custom ~kind:"even number" ~expects:"an even number"
         ~print:string_of_int
         ~parse:(fun s ->
           match int_of_string_opt s with
           | Some n when n mod 2 = 0 -> Some n
           | Some _ | None -> None)
         ())
  in
  let half p =
    Spindle.get
      Spindle.Path.(s "half" / p)
      Spindle.Returns.response
      (let+ n = Spindle.param p in
       Ok (Spindle.Response.json Wiretype.int (n / 2)))
  in
  let strict = Spindle.Test.app [ half (even ()) ] in
  check_string "handed over typed" "4"
    (Spindle.Test.call strict `GET "/half/8").body;
  let r = Spindle.Test.call strict `GET "/half/7" in
  check_status "a problem" 400 r.status;
  Alcotest.(check bool)
    "in its own words" true
    (contains ~sub:"This is not an even number." r.body);
  check_status "or not this route" 404
    (Spindle.Test.call
       (Spindle.Test.app [ half (even ~or_not_found:() ()) ])
       `GET "/half/7")
      .status

(* A path printed from its parameters is a URL that matches it again and
   hands back the same parameters -- any text, a "/" and a "%" included,
   since printing is what a redirect or a link is built from. *)
type colour = Red | Green

let colour =
  Spindle.Path.param "colour"
    (Spindle.Codec.custom ~kind:"colour"
       ~print:(function Red -> "red/ish" | Green -> "green")
       ~parse:(function
         | "red/ish" -> Some Red | "green" -> Some Green | _ -> None)
       ())

let count = Spindle.Path.int "count"
let place = Spindle.Path.(s "place" / name / count / colour / s "end")

let echo_place =
  Spindle.get place Spindle.Returns.response
    (let+ name = Spindle.param name
     and+ n = Spindle.param count
     and+ c = Spindle.param colour in
     Ok
       (Spindle.Response.json
          Wiretype.(list string)
          [ name; string_of_int n; (match c with Red -> "r" | Green -> "g") ]))

(* The compiled table answers exactly as the rule it replaced: of the
   routes of a method whose segments match, the one that ranks highest
   position by position -- a literal, then a parameter that declines, then
   one that does not -- and of equals, the one listed first; failing that,
   405 when another method matches, and otherwise 404. The rule is written
   here, over the tables it generates, so the table is checked against it
   rather than against itself. *)
type seg = Lit of string | Plain | Declining

let test_the_table_answers_as_the_rule =
  let words = [ "a"; "b"; "7"; "" ] in
  let seg =
    QCheck.Gen.(
      oneof_weighted
        [
          (3, map (fun l -> Lit l) (oneof_list [ "a"; "b"; "7" ]));
          (2, return Plain);
          (2, return Declining);
        ])
  in
  let route =
    QCheck.Gen.(
      pair (oneof_list [ `GET; `POST ]) (list_size (int_range 1 3) seg))
  in
  let case =
    QCheck.Gen.(
      pair
        (list_size (int_range 1 6) route)
        (pair
           (oneof_list [ `GET; `POST ])
           (list_size (int_range 1 3) (oneof_list words))))
  in
  let print (routes, (_, pieces)) =
    String.concat "; "
      (List.map
         (fun (m, segs) ->
           Spindle.Meth.to_string m ^ " /"
           ^ String.concat "/"
               (List.map
                  (function
                    | Lit l -> l | Plain -> "{s}" | Declining -> "{int?}")
                  segs))
         routes)
    ^ "  <-  /" ^ String.concat "/" pieces
  in
  QCheck.Test.make ~count:1000 ~name:"the table answers as the rule"
    (QCheck.make ~print case) (fun (routes, (meth, pieces)) ->
      let built =
        List.mapi
          (fun i (m, segs) ->
            let path =
              List.fold_left
                (fun (acc, n) seg ->
                  let name = Printf.sprintf "p%d" n in
                  let one =
                    match seg with
                    | Lit l -> Spindle.Path.s l
                    | Plain -> Spindle.Path.(root / str name)
                    | Declining ->
                        Spindle.Path.(root / int ~or_not_found:() name)
                  in
                  (Spindle.Path.(acc / one), n + 1))
                (Spindle.Path.root, 0) segs
              |> fst
            in
            Spindle.route m path Spindle.Returns.response
              (Spindle.Dep.return
                 (Ok (Spindle.Response.make (string_of_int i)))))
          routes
      in
      match Spindle.App.make built with
      | Error _ -> QCheck.assume_fail ()
      | Ok a -> (
          let decimal p =
            String.length p > 0
            && String.for_all (fun c -> c >= '0' && c <= '9') p
          in
          let fits segs =
            List.compare_lengths segs pieces = 0
            && List.for_all2
                 (fun seg p ->
                   match seg with
                   | Lit l -> String.equal l p
                   | Plain -> not (String.equal p "")
                   | Declining -> decimal p)
                 segs pieces
          in
          let rank =
            List.map (function Lit _ -> 2 | Declining -> 1 | Plain -> 0)
          in
          let best m =
            List.fold_left
              (fun found (i, (m', segs)) ->
                if not (Spindle.Meth.equal m m' && fits segs) then found
                else
                  match found with
                  | Some (_, best_segs)
                    when List.compare Int.compare (rank segs) (rank best_segs)
                         <= 0 ->
                      found
                  | Some _ | None -> Some (i, segs))
              None
              (List.mapi (fun i r -> (i, r)) routes)
          in
          let r = Spindle.Test.call a meth ("/" ^ String.concat "/" pieces) in
          let other = match meth with `GET -> `POST | _ -> `GET in
          match best meth with
          | Some (i, _) ->
              r.status = 200 && String.equal r.body (string_of_int i)
          | None -> (
              match best other with
              | Some _ -> r.status = 405
              | None -> r.status = 404)))

(* Text the echo can answer: JSON carries only UTF-8, and a segment of other
   bytes is a value its route cannot write. *)
let utf8_text =
  QCheck.make ~print:(Printf.sprintf "%S")
    QCheck.Gen.(
      map
        (fun points ->
          let b = Buffer.create 16 in
          List.iter (fun p -> Buffer.add_utf_8_uchar b (Uchar.of_int p)) points;
          Buffer.contents b)
        (list_small
           (oneof
              [
                int_range 0 0x7f;
                int_range 0x80 0xd7ff;
                int_range 0xe000 0x10ffff;
              ])))

let test_a_printed_path_parses_back =
  QCheck.Test.make ~count:300 ~name:"a printed path parses back"
    QCheck.(triple utf8_text int bool)
    (fun (text, n, red) ->
      QCheck.assume (not (String.equal text ""));
      let c = if red then Red else Green in
      match
        ( Spindle.Path.url place
            Spindle.Path.[ arg colour c; arg name text; arg count n ],
          Result.map_error Wiretype.Unwritable.to_string
            (Wiretype.encode
               Wiretype.(list string)
               [ text; string_of_int n; (if red then "r" else "g") ]) )
      with
      | Ok target, Ok expected ->
          let r =
            Spindle.Test.call (Spindle.Test.app [ echo_place ]) `GET target
          in
          r.status = 200 && String.equal r.body expected
      | Error m, _ | _, Error m -> QCheck.Test.fail_report m)

(* Printing is checked when it runs: each parameter once, and only the
   path's own. *)
let test_a_path_prints_only_from_its_own_parameters () =
  let orders = Spindle.Path.(s "orders" / order_id) in
  let failed args =
    match Spindle.Path.url orders args with
    | Ok u -> Alcotest.failf "printed %s" u
    | Error m -> m
  in
  Alcotest.(check (result string string))
    "each once" (Ok "/orders/7")
    (Spindle.Path.url orders [ Spindle.Path.arg order_id 7 ]);
  List.iter
    (fun (what, sub, args) ->
      Alcotest.(check bool) what true (contains ~sub (failed args)))
    [
      ("left out", "order_id", []);
      ("given twice", "twice", Spindle.Path.[ arg order_id 1; arg order_id 2 ]);
      ("not the path's", "count", Spindle.Path.[ arg order_id 1; arg count 2 ]);
      ( "printed as nothing",
        "nothing",
        [ Spindle.Path.arg (Spindle.Path.str "order_id") "" ] );
    ]

let file = Spindle.Path.rest "file"

(* The segments a rest parameter took, joined with a bar so a test can see
   where one ends: a "/" inside a segment is the segment's own. *)
let the_rest =
  let+ segs = Spindle.param file in
  Ok (Spindle.Response.make (String.concat "|" segs))

let test_the_rest_of_a_path_is_its_segments () =
  let a =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(s "static" / file)
          Spindle.Returns.response the_rest;
      ]
  in
  let body target = (Spindle.Test.call a `GET target).body in
  check_string "every segment" "css|site.css" (body "/static/css/site.css");
  check_string "none" "" (body "/static");
  check_string "an encoded slash stays in its segment" "a/b|c"
    (body "/static/a%2Fb/c");
  check_status "an empty segment is never part of one" 404
    (Spindle.Test.call a `GET "/static/a//b").status

(* A rest ranks below everything at its position, and the table goes back
   up to it when a deeper branch fails: /api/users is no route of the
   API's, so the site at the root answers it. *)
let test_the_rest_ranks_last_at_any_depth () =
  let a =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(root / file)
          Spindle.Returns.response (says "site");
        Spindle.get
          Spindle.Path.(s "api" / s "users" / user_id)
          Spindle.Returns.response (says "user");
        Spindle.get
          Spindle.Path.(s "api" / s "health")
          Spindle.Returns.response (says "health");
      ]
  in
  let body target = (Spindle.Test.call a `GET target).body in
  check_string "a literal" "health" (body "/api/health");
  check_string "a parameter" "user" (body "/api/users/7");
  check_string "a deeper branch that fails" "site" (body "/api/users");
  check_string "past a route's end" "site" (body "/api/users/7/x");
  check_string "the root itself" "site" (body "/");
  check_status "another method at one of its paths" 405
    (Spindle.Test.call a `POST "/about").status

(* A path is a resource before it is a method: one some route names under
   any method is that route's, so a rest at the root never answers GET at
   an endpoint that only takes POST. *)
let test_a_rest_takes_only_what_no_route_names () =
  let a =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(root / file)
          Spindle.Returns.response (says "site");
        Spindle.post
          Spindle.Path.(s "orders")
          Spindle.Returns.response (says "ordered");
      ]
  in
  let r = Spindle.Test.call a `GET "/orders" in
  check_status "a path an endpoint names is the endpoint's" 405 r.status;
  check_header "and allows what it answers" (Some "POST")
    (Spindle.Test.header r "allow");
  check_string "a path nobody names is the rest's" "site"
    (Spindle.Test.call a `GET "/orders/7").body;
  let r = Spindle.Test.call a `POST "/about" in
  check_status "another method where only the rest is" 405 r.status;
  check_header "allows the rest's" (Some "GET, HEAD")
    (Spindle.Test.header r "allow")

(* ---------------------------------------------------------------- *)
(* Static files.

   A directory read once, and every request a lookup among what was
   there. Each test writes its own directory rather than reading a built
   site, because what is under test is the three rules and the headers, not
   anybody's build. *)

let with_site files f =
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_dir "spindle_static" "" in
  let root = Eio.Path.(Eio.Stdenv.fs env / dir) in
  List.iter
    (fun (path, text) ->
      let p = Eio.Path.(root / path) in
      Option.iter
        (fun (parent, _) -> Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 parent)
        (Eio.Path.split p);
      Eio.Path.save ~create:(`Or_truncate 0o644) p text)
    files;
  f root

let site =
  [
    ("index.html", "FRONT DOOR");
    ("404.html", "NOT FOUND");
    ("about/index.html", "ABOUT");
    ("app/index.html", "APP SHELL");
    ("_astro/site.3f2a.js", "console.log(1)");
    ("hello world.txt", "spaced");
    ("module.wasm", "\x00asm");
    ("data.bin", "bytes");
  ]

let loaded ?not_found ?shell ?immutable ?types root =
  match Spindle.Static.load ?not_found ?shell ?immutable ?types root with
  | Ok t -> t
  | Error m -> Alcotest.failf "the site was refused: %s" m

let test_a_site_answers_by_its_three_rules () =
  with_site site @@ fun root ->
  let t =
    loaded ~not_found:"/404.html"
      ~shell:("/app/index.html", [ "/orders/" ])
      root
  in
  check_int "every file" 8 (Spindle.Static.files t);
  let a = Spindle.Test.app [ Spindle.Static.route t ] in
  let get target = Spindle.Test.call a `GET target in
  let served what target =
    let r = get target in
    check_status (target ^ " is found") 200 r.status;
    check_string (target ^ " is " ^ what) what r.body
  in
  served "FRONT DOOR" "/";
  served "ABOUT" "/about";
  served "ABOUT" "/about/index.html";
  served "APP SHELL" "/orders/7";
  served "spaced" "/hello%20world.txt";
  check_header "a document is typed" (Some "text/html; charset=utf-8")
    (Spindle.Test.header (get "/about") "content-type");
  let r = get "/nothing" in
  check_status "a miss is the not-found document" 404 r.status;
  check_string "which says so" "NOT FOUND" r.body;
  check_status "a prefix is a whole segment" 404 (get "/ordersheet").status;
  check_status "an encoded slash names no file" 404
    (get "/about%2Findex.html").status;
  check_status "a traversal is a miss" 404 (get "/../index.html").status;
  check_status "another method is 405" 405
    (Spindle.Test.call a `POST "/about").status;
  let r = Spindle.Test.call a `HEAD "/about" in
  check_status "HEAD is answered" 200 r.status;
  check_string "without the body" "" r.body

(* A directory named by its path is read when the server starts --
   [App.start], which [Spindle.serve] calls -- so the route table stays a
   constant. One that cannot be read names its route; one never started is
   our fault rather than an empty site; and a test, with no filesystem to
   start from, is told to load it. *)
let test_a_directory_is_read_when_the_server_starts () =
  with_site site @@ fun root ->
  let fs = (fst root, "") and dir = snd root in
  let app routes =
    match Spindle.App.make routes with Ok a -> a | Error m -> Alcotest.fail m
  in
  let a = app [ Spindle.Static.directory dir ] in
  check_status "before it starts, our fault" 500
    (Spindle.Test.call a `GET "/").status;
  (match Spindle.App.start a ~fs with
  | Ok () -> ()
  | Error m -> Alcotest.failf "it did not start: %s" m);
  check_string "started, its files" "FRONT DOOR"
    (Spindle.Test.call a `GET "/").body;
  (match
     Spindle.App.start
       (app [ Spindle.Static.directory (Filename.concat dir "nowhere") ])
       ~fs
   with
  | Ok () -> Alcotest.fail "a missing directory started"
  | Error m ->
      Alcotest.(check bool)
        "naming the route" true
        (contains ~sub:"GET /{file*}" m));
  match Spindle.Test.app [ Spindle.Static.directory dir ] with
  | _ -> Alcotest.fail "a test served a directory it cannot read"
  | exception Invalid_argument m ->
      Alcotest.(check bool)
        "a test is told to load it" true
        (contains ~sub:"Static.load" m)

let test_a_site_with_nothing_named_serves_its_files () =
  with_site site @@ fun root ->
  let a = Spindle.Test.app [ Spindle.Static.route (loaded root) ] in
  let get target = Spindle.Test.call a `GET target in
  check_string "a file" "ABOUT" (get "/about").body;
  let r = get "/nothing" in
  check_status "a miss is the framework's 404" 404 r.status;
  check_header "in JSON" (Some "application/json")
    (Spindle.Test.header r "content-type");
  check_status "no shell" 404 (get "/orders/7").status

let test_a_site_under_a_prefix () =
  with_site site @@ fun root ->
  let a =
    Spindle.Test.app
      [
        Spindle.Static.route ~at:Spindle.Path.(s "static") (loaded root);
        Spindle.get
          Spindle.Path.(s "about")
          Spindle.Returns.response (says "the application's");
      ]
  in
  let get target = (Spindle.Test.call a `GET target).body in
  check_string "under it" "ABOUT" (get "/static/about");
  check_string "its index" "FRONT DOOR" (get "/static");
  check_string "beside it" "the application's" (get "/about")

let test_a_file_is_typed_and_cached_by_its_prefix () =
  with_site site @@ fun root ->
  let a =
    Spindle.Test.app
      [
        Spindle.Static.route
          (loaded ~immutable:[ "/_astro/" ]
             ~types:[ (".WASM", "application/wasm") ]
             root);
      ]
  in
  let header target name =
    Spindle.Test.header (Spindle.Test.call a `GET target) name
  in
  check_header "a fingerprinted asset is kept a year"
    (Some "public, max-age=31536000, immutable")
    (header "/_astro/site.3f2a.js" "cache-control");
  check_header "and typed" (Some "text/javascript; charset=utf-8")
    (header "/_astro/site.3f2a.js" "content-type");
  check_header "a document is never kept" (Some "no-cache")
    (header "/about" "cache-control");
  check_header "a type the application adds" (Some "application/wasm")
    (header "/module.wasm" "content-type");
  check_header "an unknown one is bytes" (Some "application/octet-stream")
    (header "/data.bin" "content-type")

let test_a_matching_tag_is_304 () =
  with_site site @@ fun root ->
  let a =
    Spindle.Test.app
      [ Spindle.Static.route (loaded ~not_found:"/404.html" root) ]
  in
  let call ?(headers = []) target = Spindle.Test.call ~headers a `GET target in
  let first = call "/about" in
  let tag =
    match Spindle.Test.header first "etag" with
    | Some t -> t
    | None -> Alcotest.fail "no entity tag"
  in
  check_int "a strong tag, quoted" 34 (String.length tag);
  let unchanged headers =
    let r = call ~headers "/about" in
    check_status "not modified" 304 r.status;
    check_string "and no body" "" r.body;
    check_header "with its tag" (Some tag) (Spindle.Test.header r "etag");
    check_header "and how long to keep it" (Some "no-cache")
      (Spindle.Test.header r "cache-control")
  in
  unchanged [ ("if-none-match", tag) ];
  unchanged [ ("if-none-match", {|"other", |} ^ tag) ];
  unchanged [ ("if-none-match", {|"a,b", |} ^ tag) ];
  unchanged [ ("if-none-match", "W/" ^ tag) ];
  unchanged [ ("if-none-match", "*") ];
  unchanged [ ("if-none-match", {|"other"|}); ("if-none-match", tag) ];
  check_status "another tag is the file" 200
    (call ~headers:[ ("if-none-match", {|"other"|}) ] "/about").status;
  check_status "the not-found document is always sent" 404
    (call ~headers:[ ("if-none-match", "*") ] "/nothing").status

let test_a_site_that_cannot_be_served_is_refused () =
  with_site site @@ fun root ->
  let refused what r =
    match r with
    | Ok _ -> Alcotest.failf "%s was loaded" what
    | Error m ->
        Alcotest.(check bool)
          (what ^ ", in a sentence") true
          (String.length m > 0 && Char.equal m.[String.length m - 1] '.')
  in
  refused "a file" (Spindle.Static.load Eio.Path.(root / "data.bin"));
  refused "a directory not there"
    (Spindle.Static.load Eio.Path.(root / "missing"));
  refused "a not-found document not there"
    (Spindle.Static.load ~not_found:"/missing.html" root);
  refused "a shell not there"
    (Spindle.Static.load ~shell:("/missing.html", [ "/x/" ]) root)

(* A range of a file in memory is a slice of it; several are the whole. *)
let test_a_static_file_answers_a_range () =
  with_site site @@ fun root ->
  let a = Spindle.Test.app [ Spindle.Static.route (loaded root) ] in
  let call headers = Spindle.Test.call ~headers a `GET "/about" in
  let part = call [ ("range", "bytes=1-3") ] in
  check_status "a part" 206 part.status;
  check_string "of the file" "BOU" part.body;
  check_header "said where" (Some "bytes 1-3/5")
    (Spindle.Test.header part "content-range");
  check_header "and that ranges are answered" (Some "bytes")
    (Spindle.Test.header (call []) "accept-ranges");
  check_status "several are the whole" 200
    (call [ ("range", "bytes=0-0, 2-3") ]).status;
  check_status "past the end is 416" 416 (call [ ("range", "bytes=9-") ]).status

(* ---------------------------------------------------------------- *)
(* Files from disk *)

let files ?index ?dotfiles ?download root =
  Spindle.Test.app
    [ Spindle.Files.route ?index ?dotfiles ?download Eio.Path.(root / "files") ]

let disk =
  [
    ("files/a.txt", "ALPHABET");
    ("files/.hidden", "HIDDEN");
    ("files/docs/index.html", "DOCS");
    ("files/café.txt", "CAFE");
    ("secret.txt", "SECRET");
  ]

let test_a_file_is_served_from_disk_as_it_is () =
  with_site disk @@ fun root ->
  let a = files root in
  let r = Spindle.Test.call a `GET "/a.txt" in
  check_status "found" 200 r.status;
  check_string "as it is" "ALPHABET" r.body;
  check_header "its length" (Some "8") (Spindle.Test.header r "content-length");
  check_header "typed by its name" (Some "text/plain; charset=utf-8")
    (Spindle.Test.header r "content-type");
  check_header "checked every time" (Some "no-cache")
    (Spindle.Test.header r "cache-control");
  let tag = Option.value ~default:"" (Spindle.Test.header r "etag") in
  Alcotest.(check bool)
    "a strong tag" true
    (String.length tag > 2 && Char.equal tag.[0] '"');
  Alcotest.(check bool)
    "a date" true
    (Option.is_some (Spindle.Test.header r "last-modified"));
  (* written elsewhere and renamed over it, as the interface says to *)
  let next = Eio.Path.(root / "files" / "a.next") in
  Eio.Path.save ~create:(`Or_truncate 0o644) next "CHANGED, AND LONGER";
  Eio.Path.rename next Eio.Path.(root / "files" / "a.txt");
  let again = Spindle.Test.call a `GET "/a.txt" in
  check_string "a file that changed is read again" "CHANGED, AND LONGER"
    again.body;
  Alcotest.(check bool)
    "under another tag" false
    (String.equal tag
       (Option.value ~default:"" (Spindle.Test.header again "etag")))

let test_files_never_leave_their_directory () =
  with_site disk @@ fun root ->
  Unix.symlink
    (Filename.concat (Eio.Path.native_exn root) "secret.txt")
    (Filename.concat (Eio.Path.native_exn root) "files/out.txt");
  Unix.symlink "a.txt"
    (Filename.concat (Eio.Path.native_exn root) "files/in.txt");
  let status ?(a = files root) target =
    (Spindle.Test.call a `GET target).status
  in
  List.iter
    (fun target -> check_status target 404 (status target))
    [
      "/../secret.txt";
      "/%2e%2e/secret.txt";
      "/docs/..%2f..%2fsecret.txt";
      "/a.txt%00";
      "/docs%5c..%5ca.txt";
      "/.hidden";
      "/out.txt";
      "/docs";
      "/nothing.txt";
      "/a.txt/below";
    ];
  check_status "a symlink within it is followed" 200 (status "/in.txt");
  check_status "a dotfile, where asked" 200
    (status ~a:(files ~dotfiles:true root) "/.hidden");
  check_status "a directory is its index, where one is named" 200
    (status ~a:(files ~index:"index.html" root) "/docs");
  check_status "and no listing without one" 404
    (status ~a:(files ~index:"index.html" root) "/")

let test_a_file_answers_its_conditions_and_ranges () =
  with_site disk @@ fun root ->
  let a = files root in
  (* a clock past the file's date, since a date later than now is none *)
  let call ?(meth = `GET) headers =
    Spindle.Test.call ~now:3_000_000_000_000 ~headers a meth "/a.txt"
  in
  let whole = call [] in
  let tag = Option.value ~default:"" (Spindle.Test.header whole "etag")
  and date =
    Option.value ~default:"" (Spindle.Test.header whole "last-modified")
  in
  let part = call [ ("range", "bytes=2-4") ] in
  check_status "a part" 206 part.status;
  check_string "of it" "PHA" part.body;
  check_header "its length" (Some "3")
    (Spindle.Test.header part "content-length");
  check_header "and where it is" (Some "bytes 2-4/8")
    (Spindle.Test.header part "content-range");
  check_string "the last so many" "BET" (call [ ("range", "bytes=-3") ]).body;
  check_string "from there to the end" "BET"
    (call [ ("range", "bytes=5-") ]).body;
  let past = call [ ("range", "bytes=8-") ] in
  check_status "past the end" 416 past.status;
  check_header "says how long it is" (Some "bytes */8")
    (Spindle.Test.header past "content-range");
  check_status "several are the whole" 200
    (call [ ("range", "bytes=0-1, 4-5") ]).status;
  check_status "another unit is the whole" 200
    (call [ ("range", "pages=1-2") ]).status;
  check_status "a range that ends before it starts is the whole" 200
    (call [ ("range", "bytes=4-2") ]).status;
  check_status "a HEAD is never a part" 200
    (call ~meth:`HEAD [ ("range", "bytes=2-4") ]).status;
  check_status "a range of the file it was" 206
    (call [ ("range", "bytes=2-4"); ("if-range", tag) ]).status;
  check_status "or of the date it was" 206
    (call [ ("range", "bytes=2-4"); ("if-range", date) ]).status;
  check_status "of another is the whole" 200
    (call [ ("range", "bytes=2-4"); ("if-range", {|"other"|}) ]).status;
  check_status "and a weak tag never matches" 200
    (call [ ("range", "bytes=2-4"); ("if-range", "W/" ^ tag) ]).status;
  check_status "held already, by its tag" 304
    (call [ ("if-none-match", tag) ]).status;
  check_status "or by its date" 304
    (call [ ("if-modified-since", date) ]).status;
  check_status "a tag wins over a date" 200
    (call [ ("if-none-match", {|"other"|}); ("if-modified-since", date) ])
      .status;
  check_status "a date in the future is no date" 200
    (call [ ("if-modified-since", "Fri, 01 Jan 2100 00:00:00 GMT") ]).status;
  check_status "a tag it is not fails If-Match" 412
    (call [ ("if-match", {|"other"|}) ]).status;
  check_status "and its own passes" 200 (call [ ("if-match", tag) ]).status;
  check_status "a weak one fails, since If-Match is strong" 412
    (call [ ("if-match", "W/" ^ tag) ]).status;
  check_status "changed since the date asked is 412" 412
    (call [ ("if-unmodified-since", "Thu, 01 Jan 1970 00:00:00 GMT") ]).status;
  check_status "If-Match is asked before If-None-Match" 412
    (call [ ("if-match", {|"other"|}); ("if-none-match", tag) ]).status

let test_a_download_is_named () =
  with_site disk @@ fun root ->
  let a = files ~download:true root in
  check_header "a plain name, quoted" (Some {|attachment; filename="a.txt"|})
    (Spindle.Test.header
       (Spindle.Test.call a `GET "/a.txt")
       "content-disposition");
  check_header "another, beside its ASCII"
    (Some {|attachment; filename="caf__.txt"; filename*=UTF-8''caf%C3%A9.txt|})
    (Spindle.Test.header
       (Spindle.Test.call a `GET "/caf%C3%A9.txt")
       "content-disposition")

(* The head is written from the file as it was; a file replaced before its
   body is read sends none of another file under the first one's length. *)
let test_a_file_replaced_before_its_body_sends_nothing () =
  with_site disk @@ fun root ->
  let a = files root in
  let response, _ =
    Spindle.App.handle a
      (Spindle.Request.make ~now:(fun () -> 0) `GET "/a.txt")
      ~body:
        {
          Spindle.Body.whole = (fun () -> Ok "");
          part = (fun ~max:_ -> Ok `End);
        }
  in
  let next = Eio.Path.(root / "files" / "a.next") in
  Eio.Path.save ~create:(`Or_truncate 0o644) next "SOMETHING ELSE";
  Eio.Path.rename next Eio.Path.(root / "files" / "a.txt");
  match Spindle.Response.content response with
  | Spindle.Response.Stream { produce; length; _ } ->
      check_int "its head said eight" 8 (Option.value ~default:0 length);
      let sent = Buffer.create 8 in
      ignore
        (produce (fun s ->
             Buffer.add_string sent s;
             Ok ())
          : (unit, Spindle.Response.gone) result);
      check_string "and nothing was sent" "" (Buffer.contents sent)
  | Spindle.Response.Buffered _ | Spindle.Response.Takeover _ ->
      Alcotest.fail "a file is a stream"

let test_a_directory_not_there_is_refused_at_start () =
  Eio_main.run @@ fun env ->
  match Spindle.App.make [ Spindle.Files.directory "/nowhere/at/all" ] with
  | Error m -> Alcotest.fail m
  | Ok app -> (
      match Spindle.App.start app ~fs:(Eio.Stdenv.fs env) with
      | Ok () -> Alcotest.fail "a directory not there was started"
      | Error m ->
          Alcotest.(check bool)
            "said, naming it" true
            (contains ~sub:"/nowhere/at/all" m))

(* A file the build wrote precompressed siblings for is served as the one
   the client takes, typed as the file, and says it varies. *)
let check_siblings answer =
  let r = answer "gzip, br" in
  check_header "brotli, where it is taken and there" (Some "br")
    (Spindle.Test.header r "content-encoding");
  check_string "its bytes the sibling's" "BROTLI" r.body;
  check_header "typed as the file" (Some "text/javascript; charset=utf-8")
    (Spindle.Test.header r "content-type");
  check_header "and varying by the coding" (Some "Accept-Encoding")
    (Spindle.Test.header r "vary");
  check_string "the client's weights decide" "GZIP"
    (answer "br;q=0.5, gzip").body;
  check_string "a coding there is none of is passed over" "GZIP"
    (answer "zstd, gzip").body;
  let plain = answer "identity" in
  check_string "and one that takes none gets the file" "console.log(1)"
    plain.body;
  check_header "varying all the same" (Some "Accept-Encoding")
    (Spindle.Test.header plain "vary")

let sibling_site =
  [
    ("app.js", "console.log(1)");
    ("app.js.br", "BROTLI");
    ("app.js.gz", "GZIP");
    ("plain.txt", "PLAIN");
  ]

let test_a_static_file's_precompressed_sibling_is_served () =
  with_site sibling_site @@ fun root ->
  let a = Spindle.Test.app [ Spindle.Static.route (loaded root) ] in
  check_siblings (fun accept ->
      Spindle.Test.call a `GET "/app.js"
        ~headers:[ ("accept-encoding", accept) ]);
  check_string "a coding taken on a later line is taken all the same" "BROTLI"
    (Spindle.Test.call a `GET "/app.js"
       ~headers:[ ("accept-encoding", "identity"); ("accept-encoding", "br") ])
      .body;
  check_header "a file with none says nothing of a coding" None
    (Spindle.Test.header
       (Spindle.Test.call a `GET "/plain.txt"
          ~headers:[ ("accept-encoding", "br") ])
       "vary")

let test_a_file's_precompressed_sibling_is_served () =
  with_site (List.map (fun (n, b) -> ("files/" ^ n, b)) sibling_site)
  @@ fun root ->
  let a = Spindle.Test.app [ Spindle.Files.route Eio.Path.(root / "files") ] in
  check_siblings (fun accept ->
      Spindle.Test.call a `GET "/app.js"
        ~headers:[ ("accept-encoding", accept) ])

(* ---------------------------------------------------------------- *)
(* A body read as it arrives *)

(* Reads the body a part at a time and says how much came, answering a
   body it could not read as the framework would have. *)
let rec tally body ~parts ~bytes =
  match Spindle.Body.read body with
  | Ok (`Data s) ->
      tally body ~parts:(parts + 1) ~bytes:(bytes + String.length s)
  | Ok `End -> Ok (Printf.sprintf "%d parts, %d bytes" parts bytes)
  | Error e -> Error (Spindle.Body.refusal e)

let upload =
  Spindle.post
    Spindle.Path.(s "upload")
    Spindle.Returns.text
    (let+ body =
       Spindle.body_stream
         ~content_type:(String.equal "application/octet-stream")
         ~max:200_000 ()
     in
     tally body ~parts:0 ~bytes:0)

let test_a_streamed_body_is_read_in_parts () =
  let a = Spindle.Test.app [ upload ] in
  let call ?(headers = [ ("content-type", "application/octet-stream") ]) body =
    Spindle.Test.call ~headers ~body a `POST "/upload"
  in
  check_string "a part at a time" "3 parts, 150000 bytes"
    (call (String.make 150_000 'x')).body;
  check_string "an empty body is its end" "0 parts, 0 bytes" (call "").body;
  check_status "past the route's own limit" 413
    (call (String.make 200_001 'x')).status;
  check_status "another type, before any is read" 415
    (call ~headers:[ ("content-type", "text/plain") ] "x").status

let test_a_body_read_after_its_handler_reads_nothing () =
  let late = ref None in
  let a =
    Spindle.Test.app
      [
        Spindle.post
          Spindle.Path.(s "late")
          Spindle.Returns.response
          (let+ body = Spindle.body_stream ~max:1000 () in
           Ok
             (Spindle.Response.stream (fun send ->
                  late := Some (Spindle.Body.read body);
                  send "sent")));
      ]
  in
  check_string "answered" "sent"
    (Spindle.Test.call ~body:"abc" a `POST "/late").body;
  Alcotest.(check bool)
    "the body was over" true
    (match !late with Some (Ok `End) -> true | Some _ | None -> false)

let test_a_route_reads_one_body () =
  let m =
    refused
      [
        Spindle.post
          Spindle.Path.(s "twice")
          Spindle.Returns.text
          (let+ _ = Spindle.body_stream ~max:10 () and+ s = Spindle.body in
           Ok s);
      ]
  in
  Alcotest.(check bool) "named" true (contains ~sub:"read one way" m);
  let a =
    Spindle.Test.app
      [
        Spindle.post
          Spindle.Path.(s "twice")
          Spindle.Returns.text
          (let+ a = Spindle.body and+ b = Spindle.body in
           Ok (a ^ b));
      ]
  in
  check_string "two that read it whole share one reading" "abab"
    (Spindle.Test.call ~body:"ab" a `POST "/twice").body

let test_a_rest_before_the_end_is_refused () =
  let m =
    refused
      [
        Spindle.get
          Spindle.Path.(s "a" / file / s "b")
          Spindle.Returns.response the_rest;
      ]
  in
  Alcotest.(check bool) "named" true (contains ~sub:"before its end" m);
  let m =
    refused
      [
        Spindle.get
          Spindle.Path.(s "a" / file)
          Spindle.Returns.response the_rest;
        Spindle.get
          Spindle.Path.(s "a" / Spindle.Path.rest "other")
          Spindle.Returns.response the_rest;
      ]
  in
  Alcotest.(check bool)
    "two rests at one place" true
    (contains ~sub:"could both answer" m)

let test_the_rest_prints_and_parses_back () =
  let static = Spindle.Path.(s "static" / file) in
  let url segs = Spindle.Path.url static [ Spindle.Path.arg file segs ] in
  Alcotest.(check (result string string))
    "each segment encoded" (Ok "/static/a%20b/c%2Fd")
    (url [ "a b"; "c/d" ]);
  Alcotest.(check (result string string)) "none" (Ok "/static") (url []);
  List.iter
    (fun segs ->
      match url segs with
      | Ok u -> Alcotest.failf "an empty segment printed as %s" u
      | Error m ->
          Alcotest.(check bool)
            "an empty segment is refused, naming it" true
            (contains ~sub:"empty segment" m))
    [ [ "a"; ""; "b" ]; [ "a"; "" ]; [ ""; "a" ] ];
  check_string "the pattern" "/static/{file*}" (Spindle.Path.pattern static);
  let a =
    Spindle.Test.app [ Spindle.get static Spindle.Returns.response the_rest ]
  in
  check_string "read back" "a b|c/d"
    (Spindle.Test.call a `GET "/static/a%20b/c%2Fd").body

(* Any segments that are not empty print as a URL that reads them back,
   whatever they hold. *)
let test_a_printed_rest_parses_back =
  QCheck.Test.make ~count:300 ~name:"a printed rest parses back"
    QCheck.(list_small (string_size_of Gen.(1 -- 8) Gen.char))
    (fun segs ->
      let static = Spindle.Path.(s "static" / file) in
      match Spindle.Path.url static [ Spindle.Path.arg file segs ] with
      | Ok target ->
          let a =
            Spindle.Test.app
              [ Spindle.get static Spindle.Returns.response the_rest ]
          in
          String.equal (String.concat "|" segs)
            (Spindle.Test.call a `GET target).body
      | Error m -> QCheck.Test.fail_report m)

(* A 64-bit key past what a float holds exactly is read exactly, and a
   custom codec's refusal reads as a sentence whatever its kind. *)
let test_int64_and_a_custom_kind_read_as_sentences () =
  let id = Spindle.Path.int64 "id" in
  let tile =
    Spindle.Path.param "tile"
      (Spindle.Codec.custom ~kind:"int64" ~parse:Int64.of_string_opt
         ~print:Int64.to_string ())
  in
  let a =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(s "users" / id)
          Spindle.Returns.response
          (let+ id = Spindle.param id in
           Ok (Spindle.Response.make (Int64.to_string id)));
        Spindle.get
          Spindle.Path.(s "tiles" / tile)
          Spindle.Returns.response
          (let+ _ = Spindle.param tile in
           Ok (Spindle.Response.make "tile"));
      ]
  in
  check_string "exactly" "9007199254740993"
    (Spindle.Test.call a `GET "/users/9007199254740993").body;
  Alcotest.(check bool)
    "a whole number" true
    (contains ~sub:"This is not a whole number."
       (Spindle.Test.call a `GET "/users/0x1f").body);
  Alcotest.(check bool)
    "a valid kind" true
    (contains ~sub:"This is not a valid int64."
       (Spindle.Test.call a `GET "/tiles/abc").body)

(* ------------------------------------------------------------------ *)
(* Answers, codes and problems *)

(* What a route returns is named where the route is, and the endpoint
   returns the plain value the framework encodes: the status is the
   model's, and a cookie the endpoint set goes with it. *)
let test_an_answer_encodes_what_the_route_returns () =
  let made =
    Spindle.post
      Spindle.Path.(s "made")
      (Spindle.Returns.json ~status:`Created greeting_json)
      (let+ g = Spindle.json greeting_json
       and+ set_cookie = Spindle.set_cookie in
       set_cookie
         (Spindle.Cookie.make
            (Spindle.Cookie.named "seen" Spindle.Codec.string)
            "1");
       Ok g)
  in
  let r =
    Spindle.Test.call
      (Spindle.Test.app [ made ])
      `POST "/made" ~body:{|{"name":"kim","times":2}|}
  in
  check_status "the answer's status" 201 r.status;
  check_string "the value, encoded" {|{"name":"kim","times":2}|} r.body;
  Alcotest.(check bool)
    "and its cookie" true
    (contains ~sub:"seen=1"
       (Option.value (Spindle.Test.header r "set-cookie") ~default:""))

let test_a_page_and_text_are_their_media_types () =
  let a =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(s "page")
          Spindle.Returns.html
          (Spindle.Dep.return (Ok "<h1>Hello</h1>"));
        Spindle.get
          Spindle.Path.(s "text")
          Spindle.Returns.text
          (Spindle.Dep.return (Ok "Hello"));
      ]
  in
  List.iter
    (fun (target, body, media) ->
      let r = Spindle.Test.call a `GET target in
      check_status target 200 r.status;
      check_string target body r.body;
      check_header target (Some media) (Spindle.Test.header r "content-type"))
    [
      ("/page", "<h1>Hello</h1>", "text/html; charset=utf-8");
      ("/text", "Hello", "text/plain; charset=utf-8");
    ]

let gone = code "gone" `Gone

(* A route table App.make refuses is a constant written in source, so
   serve raises before it listens, naming the routes. *)
let test_serve_refuses_routes_before_it_listens () =
  Eio_main.run @@ fun env ->
  let hello =
    Spindle.get Spindle.Path.root Spindle.Returns.text
      (Spindle.Dep.return (Ok "a"))
  in
  match Spindle.serve env ~port:0 [ hello; hello ] with
  | () -> Alcotest.fail "it served"
  | exception Invalid_argument m ->
      Alcotest.(check bool) "named" true (contains ~sub:"could both answer" m)

(* Told to stop, it stops: it listened, said where, and returned. *)
let test_serve_listens_and_stops () =
  Eio_main.run @@ fun env ->
  let stop, stopped = Eio.Promise.create () in
  let told = ref None in
  Spindle.serve env ~port:0 ~stop
    ~ready:(fun where ->
      told := Some where;
      Eio.Promise.resolve stopped ())
    [
      Spindle.get Spindle.Path.root Spindle.Returns.text
        (Spindle.Dep.return (Ok "a"));
    ];
  Alcotest.(check bool) "said where" true (Option.is_some !told)

(* A cookie and a header the endpoint set go with its value, and are
   dropped with a refusal, which says only what it says. *)
let test_what_an_endpoint_sets_goes_only_with_ok () =
  let a =
    Spindle.Test.app
      [
        Spindle.get ~refuses:[ gone ]
          Spindle.Path.(s "set")
          Spindle.Returns.text
          (let+ fail = Spindle.Query.required "fail" Spindle.Codec.bool
           and+ set_cookie = Spindle.set_cookie
           and+ add_header = Spindle.add_header in
           set_cookie
             (Spindle.Cookie.make
                (Spindle.Cookie.named "seen" Spindle.Codec.string)
                "1");
           add_header ("x-seen", "yes");
           if fail then Error (Spindle.Refusal.make gone "It went.")
           else Ok "kept");
      ]
  in
  let ok = Spindle.Test.call a `GET "/set?fail=false" in
  check_string "the value" "kept" ok.body;
  Alcotest.(check bool)
    "the cookie" true
    (contains ~sub:"seen=1"
       (Option.value (Spindle.Test.header ok "set-cookie") ~default:""));
  check_header "the header" (Some "yes") (Spindle.Test.header ok "x-seen");
  let refused = Spindle.Test.call a `GET "/set?fail=true" in
  check_status "the refusal" 410 refused.status;
  check_header "no cookie" None (Spindle.Test.header refused "set-cookie");
  check_header "no header" None (Spindle.Test.header refused "x-seen")

(* A function kept past the answer writes to nothing: the next request is
   not given what the last one's leftover set, and the bug is logged. *)
let test_a_call_after_the_answer_changes_nothing () =
  let kept = ref None in
  let a =
    Spindle.Test.app
      [
        Spindle.get
          Spindle.Path.(s "keep")
          Spindle.Returns.text
          (let+ set_cookie = Spindle.set_cookie in
           kept := Some set_cookie;
           Ok "kept");
      ]
  in
  let lines =
    captured ~level:(Some Logs.Warning) (fun () ->
        ignore (Spindle.Test.call a `GET "/keep" : Spindle.Test.response);
        Option.iter
          (fun f ->
            f
              (Spindle.Cookie.make
                 (Spindle.Cookie.named "late" Spindle.Codec.string)
                 "1"))
          !kept)
  in
  Alcotest.(check bool)
    "logged, naming the route" true
    (List.exists (contains ~sub:"/keep set a cookie or a header after") lines);
  let next = Spindle.Test.call a `GET "/keep" in
  check_header "the next request is not given it" None
    (Spindle.Test.header next "set-cookie")

(* A route's codes are its own and every one its inputs carry, so a refusal
   made from anything else is the route's bug -- which a test that reaches
   it is told at once. *)
let test_a_code_nobody_declared_is_the_routes_bug () =
  let signed_in =
    Spindle.Dep.of_request ~needs:[]
      ~refuses:[ code "signed_out" `Unauthorized ]
      (fun _ ->
        Error
          (Spindle.Refusal.make (code "signed_out" `Unauthorized) "Sign in."))
  in
  let declared =
    Spindle.get ~refuses:[ gone ]
      Spindle.Path.(s "declared")
      Spindle.Returns.response
      (Spindle.Dep.return (Error (Spindle.Refusal.make gone "It went.")))
  in
  let carried =
    Spindle.get
      Spindle.Path.(s "carried")
      Spindle.Returns.response
      (let+ () = signed_in in
       Ok (Spindle.Response.make "in"))
  in
  let undeclared =
    Spindle.get
      Spindle.Path.(s "undeclared")
      Spindle.Returns.response
      (Spindle.Dep.return (Error (Spindle.Refusal.make gone "It went.")))
  in
  let a = Spindle.Test.app [ declared; carried; undeclared ] in
  check_status "declared by the route" 410
    (Spindle.Test.call a `GET "/declared").status;
  check_status "carried by an input" 401
    (Spindle.Test.call a `GET "/carried").status;
  check_status "the framework's own need no declaring" 404
    (Spindle.Test.call a `GET "/nowhere").status;
  Alcotest.(check (list string))
    "a route lists what its inputs carry" [ "signed_out" ]
    (List.map Spindle.Refusal.Code.name (Spindle.Route.info carried).codes);
  match Spindle.Test.call a `GET "/undeclared" with
  | _ -> Alcotest.fail "a code nobody declared passed a test"
  | exception Invalid_argument m ->
      Alcotest.(check bool) "naming it" true (contains ~sub:"gone" m)

(* A route whose success is one of several answers under the status the
   endpoint chose, the value's or none; a status it did not list is still
   sent and is the route's bug, which a test is told. *)
let test_a_route_answers_the_status_it_chose () =
  let name = Spindle.Path.str "name" in
  let upsert =
    Spindle.put
      Spindle.Path.(s "users" / name)
      (Spindle.Returns.json_response Wiretype.string
         ~statuses:
           [ (`Created, "The user was made."); (`OK, "The user was replaced.") ])
      (let+ name = Spindle.param name in
       match name with
       | "ada" -> Ok (`OK, name)
       | "stray" -> Ok (`Accepted, name)
       | _ -> Ok (`Created, name))
  in
  let subscribe =
    Spindle.post
      Spindle.Path.(s "subscribe")
      (Spindle.Returns.empty_response
         ~statuses:
           [ (`Created, "Subscribed."); (`No_content, "Already subscribed.") ])
      (let+ again = Spindle.Query.optional "again" Spindle.Codec.bool in
       match again with
       | Some true -> Ok `No_content
       | Some false | None -> Ok `Created)
  in
  let a = Spindle.Test.app [ upsert; subscribe ] in
  let made = Spindle.Test.call a `PUT "/users/kim" in
  check_status "made" 201 made.status;
  check_string "with its value" {|"kim"|} made.body;
  check_status "replaced" 200 (Spindle.Test.call a `PUT "/users/ada").status;
  let subscribed = Spindle.Test.call a `POST "/subscribe" in
  check_status "no body, made" 201 subscribed.status;
  check_string "and nothing in it" "" subscribed.body;
  check_status "no body, as it was" 204
    (Spindle.Test.call a `POST "/subscribe?again=true").status;
  (* The server sends what the endpoint said and says whose bug it is. *)
  let response, answered =
    Spindle.App.handle a
      (Spindle.Request.make ~now:(fun () -> 0) `PUT "/users/stray")
      ~body:
        {
          Spindle.Body.whole = (fun () -> Ok "");
          part = (fun ~max:_ -> Ok `End);
        }
  in
  check_status "an unlisted status is sent" 202
    (Spindle.Status.to_int (Spindle.Response.status response));
  (match answered.undeclared with
  | Some (Spindle.App.Status s) ->
      check_status "and named" 202 (Spindle.Status.to_int s)
  | Some (Spindle.App.Code _) | None -> Alcotest.fail "not said to be unlisted");
  match Spindle.Test.call a `PUT "/users/stray" with
  | _ -> Alcotest.fail "a status nobody listed passed a test"
  | exception Invalid_argument m ->
      Alcotest.(check bool) "naming it" true (contains ~sub:"202" m)

(* The statuses a route lists are ones it means: at least one, each a
   success -- failing is a refusal -- and each once. *)
let test_a_routes_statuses_are_checked () =
  let listing statuses =
    Spindle.get
      Spindle.Path.(s "x")
      (Spindle.Returns.json_response Wiretype.string ~statuses)
      (Spindle.Dep.return (Ok (`OK, "x")))
  in
  List.iter
    (fun (why, statuses, says) ->
      match Spindle.Test.app [ listing statuses ] with
      | _ -> Alcotest.failf "%s: the app was made" why
      | exception Invalid_argument m ->
          Alcotest.(check bool) why true (contains ~sub:says m))
    [
      ("none", [], "no status");
      ("a failure", [ (`Not_found, "Missing.") ], "not a success");
      ("twice", [ (`OK, "One."); (`OK, "Two.") ], "twice");
    ]

(* A middleware's codes are declared where the app is made and held to what
   a route's are, and one declared nowhere is a bug whether or not a route
   ran: this one answers before any does. *)
let test_a_middlewares_codes_are_declared () =
  let closed = code "closed" `Service_unavailable in
  let shut _handler _req =
    Spindle.Response.refusal (Spindle.Refusal.make closed "Back in a minute.")
  in
  let hello =
    Spindle.get
      Spindle.Path.(s "hello")
      Spindle.Returns.text
      (Spindle.Dep.return (Ok "hello"))
  in
  (match
     Spindle.Test.call
       (Spindle.Test.app ~middleware:[ shut ] [ hello ])
       `GET "/hello"
   with
  | _ -> Alcotest.fail "a middleware's undeclared code passed a test"
  | exception Invalid_argument m ->
      Alcotest.(check bool) "naming it" true (contains ~sub:"closed" m));
  check_status "declared, it is answered" 503
    (Spindle.Test.call
       (Spindle.Test.app ~middleware:[ shut ] ~codes:[ closed ] [ hello ])
       `GET "/hello")
      .status;
  let refusing c =
    Spindle.get ~refuses:[ c ]
      Spindle.Path.(s "a")
      Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.empty ())))
  in
  (match
     Spindle.App.make ~codes:[ code "closed" `Gone ] [ refusing closed ]
   with
  | Error m ->
      Alcotest.(check bool)
        "one meaning, the application's among them" true
        (contains ~sub:"the application" m)
  | Ok _ -> Alcotest.fail "a middleware's code was given a second meaning");
  match
    Spindle.App.make
      ~codes:
        [
          Spindle.Refusal.Code.make "signed_out" ~status:`Unauthorized
            ~doc:"Sign in.";
        ]
      []
  with
  | Error m ->
      Alcotest.(check bool)
        "a 401 names its challenge" true
        (contains ~sub:"challenge" m)
  | Ok _ -> Alcotest.fail "a middleware's 401 with no challenge was accepted"

(* Every problem with the request's inputs is told at once, each at its
   place -- and a refusal about something else ends the request with none
   of them. *)
let test_every_problem_is_told_at_once () =
  let listed =
    Spindle.get
      Spindle.Path.(s "orders" / order_id)
      Spindle.Returns.response
      (let+ _ = Spindle.param order_id
       and+ _ = Spindle.Query.required "page" Spindle.Codec.int
       and+ _ = Spindle.Header.optional "x-count" Spindle.Codec.int in
       Ok (Spindle.Response.make "ok"))
  in
  let r =
    Spindle.Test.call
      (Spindle.Test.app [ listed ])
      `GET "/orders/x?page=two"
      ~headers:[ ("x-count", "some") ]
  in
  check_status "one 400" 400 r.status;
  check_string "with all three"
    {|{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"path.order_id","code":"malformed","message":"This is not a whole number."},{"at":"query.page","code":"malformed","message":"This is not a whole number."},{"at":"header.x-count","code":"malformed","message":"This is not a whole number."}]}|}
    r.body;
  check_string "a missing one says so" {|"code":"required"|}
    (let r = Spindle.Test.call (Spindle.Test.app [ listed ]) `GET "/orders/7" in
     if contains ~sub:{|"at":"query.page","code":"required"|} r.body then
       {|"code":"required"|}
     else r.body);
  let signed_out = code "signed_out" `Unauthorized in
  let guarded =
    Spindle.get
      Spindle.Path.(s "guarded")
      Spindle.Returns.response
      (let+ _ = Spindle.Query.required "page" Spindle.Codec.int
       and+ () =
         Spindle.Dep.of_request ~needs:[] ~refuses:[ signed_out ] (fun _ ->
             Error (Spindle.Refusal.make signed_out "Sign in."))
       in
       Ok (Spindle.Response.make "ok"))
  in
  check_status "anything else ends it" 401
    (Spindle.Test.call (Spindle.Test.app [ guarded ]) `GET "/guarded?page=no")
      .status

type shade = Blue | Gold

let colour_codec =
  Spindle.Codec.enum ~kind:"colour"
    (function Blue -> "blue" | Gold -> "gold")
    [ Blue; Gold ]

(* A codec reads the same wherever the text arrives, and a list is every
   value a query parameter is given. *)
let test_typed_inputs () =
  let route =
    Spindle.get
      Spindle.Path.(s "typed")
      (Spindle.Returns.json Wiretype.(list string))
      (let+ tags = Spindle.Query.list "tag" colour_codec
       and+ loud = Spindle.Query.optional "loud" Spindle.Codec.bool
       and+ n =
         Spindle.Cookie.optional (Spindle.Cookie.named "n" Spindle.Codec.int)
       in
       Ok
         (List.map (function Blue -> "b" | Gold -> "g") tags
         @ [
             (match loud with Some true -> "loud" | Some false | None -> "-");
             (match n with Some n -> string_of_int n | None -> "-");
           ]))
  in
  let a = Spindle.Test.app [ route ] in
  check_string "each, in order" {|["b","g","b","loud","3"]|}
    (Spindle.Test.call a `GET "/typed?tag=blue&tag=gold&tag=blue&loud=true"
       ~headers:[ ("cookie", "n=3") ])
      .body;
  check_string "none of them" {|["-","-"]|}
    (Spindle.Test.call a `GET "/typed").body;
  let r = Spindle.Test.call a `GET "/typed?tag=red&loud=yes" in
  check_status "a word not in the set" 400 r.status;
  Alcotest.(check bool)
    "says which it takes" true
    (contains ~sub:"This is not one of blue, gold." r.body);
  Alcotest.(check bool)
    "and a bool is true or false" true
    (contains ~sub:{|"at":"query.loud"|} r.body)

type some_stream

(* A stream sends the events it declares, each spelled once, JSON or text,
   with its id where it has one; one of its stream it does not declare still
   goes -- the client asked for the stream -- and is the route's bug in the
   log. *)
let test_a_stream_sends_its_declared_events () =
  let state : (int, some_stream) Spindle.Event.kind =
    Spindle.Event.json "state" Wiretype.int
  in
  let token : (string, some_stream) Spindle.Event.kind =
    Spindle.Event.text "token"
  in
  let other : (string, some_stream) Spindle.Event.kind =
    Spindle.Event.json "other" Wiretype.string
  in
  let stream =
    Spindle.get
      Spindle.Path.(s "stream")
      (Spindle.Returns.events Spindle.Event.[ declare state; declare token ])
      (Spindle.Dep.return
         (Ok
            (fun send ->
              let ( let* ) = Result.bind in
              let* () = send (Spindle.Event.retry 1000) in
              let* () = send (Spindle.Event.make ~id:"7" state 7) in
              let* () = send (Spindle.Event.make token "two\r\nlines") in
              let* () = send (Spindle.Event.comment "keep-alive") in
              send (Spindle.Event.make other "stray"))))
  in
  let r = Spindle.Test.call (Spindle.Test.app [ stream ]) `GET "/stream" in
  check_header "as events" (Some "text/event-stream")
    (Spindle.Test.header r "content-type");
  check_string "framed"
    "retry: 1000\n\n\
     event: state\n\
     id: 7\n\
     data: 7\n\n\
     event: token\n\
     data: two\n\
     data: lines\n\n\
     : keep-alive\n\n\
     event: other\n\
     data: \"stray\"\n\n"
    r.body

(* ------------------------------------------------------------------ *)
(* What an app says about itself *)

(* A package's own key, beside the framework's. *)
let rate_limit : int Spindle.Meta.key = Spindle.Meta.key ()

(* Everything a route reads, answers and may refuse with, and what it says
   of itself, listed without a request -- enough to document it. *)
(* A client branches on a code's name, so two routes may share one only if
   it means the same thing in both -- the framework's own included. *)
let test_a_code_means_one_thing () =
  let at path c =
    Spindle.get ~refuses:[ c ]
      Spindle.Path.(s path)
      Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.empty ())))
  in
  let conflict status =
    Spindle.Refusal.Code.make "conflict" ~status ~doc:"Somebody was first."
  in
  (match
     Spindle.App.make
       [ at "a" (conflict `Conflict); at "b" (conflict `Unprocessable_content) ]
   with
  | Error m ->
      Alcotest.(check bool) "names the code" true (contains ~sub:"conflict" m);
      Alcotest.(check bool)
        "and both routes" true
        (contains ~sub:"GET /a" m && contains ~sub:"GET /b" m)
  | Ok _ -> Alcotest.fail "one name, two statuses, was accepted");
  (match
     Spindle.App.make
       [ at "a" (conflict `Conflict); at "b" (conflict (`Code 409)) ]
   with
  | Ok _ -> ()
  | Error m -> Alcotest.failf "one meaning, spelled twice, was refused: %s" m);
  match
    Spindle.App.make
      [
        at "a"
          (Spindle.Refusal.Code.make "not_found" ~status:`Gone ~doc:"Gone.");
      ]
  with
  | Error m ->
      Alcotest.(check bool)
        "the framework's own" true
        (contains ~sub:"the framework" m)
  | Ok _ -> Alcotest.fail "a framework code was given another meaning"

(* A HEAD is answered by the GET route; a route of its own could never be. *)
let test_a_head_route_is_refused () =
  match
    Spindle.App.make
      [
        Spindle.route `HEAD
          Spindle.Path.(s "x")
          Spindle.Returns.response
          (Spindle.Dep.return (Ok (Spindle.Response.empty ())));
      ]
  with
  | Error m -> Alcotest.(check bool) "says why" true (contains ~sub:"GET" m)
  | Ok _ -> Alcotest.fail "a HEAD route was accepted"

(* A body refused in the route's own words: the code is the dependency's to
   declare, so the route lists it and a test reaching it does not raise. *)
let test_a_bodys_own_refusal_is_declared () =
  let wrong = code "wrong_shape" `Bad_request in
  let route =
    Spindle.post
      Spindle.Path.(s "echo")
      Spindle.Returns.response
      (let+ g =
         Spindle.json ~refusal:(wrong, "Not a greeting.") greeting_json
       in
       Ok (Spindle.Response.json greeting_json g))
  in
  let a = Spindle.Test.app [ route ] in
  (match Spindle.App.routes a with
  | [ info ] ->
      Alcotest.(check (list string))
        "listed, beside the type a JSON body refuses"
        [ "wrong_shape"; "unsupported_media_type" ]
        (List.map Spindle.Refusal.Code.name info.codes)
  | _ -> Alcotest.fail "one route");
  let r =
    Spindle.Test.call a `POST "/echo"
      ~headers:[ ("content-type", "application/json") ]
      ~body:{|{"name": 3}|}
  in
  check_status "its status" 400 r.status;
  Alcotest.(check bool)
    "its words" true
    (contains ~sub:"Not a greeting." r.body);
  Alcotest.(check bool) "its code" true (contains ~sub:"wrong_shape" r.body)

(* One spelling per status: every name has its number and comes back from
   it, and a code declared by number is the named status. *)
let test_a_status_has_one_spelling () =
  List.iter
    (fun st ->
      let n = Spindle.Status.to_int st in
      check_int "round trip" n (Spindle.Status.to_int (Spindle.Status.of_int n));
      Alcotest.(check bool)
        (Printf.sprintf "%d is named" n)
        true
        (match Spindle.Status.of_int n with `Code _ -> false | _ -> true);
      Alcotest.(check bool)
        (Printf.sprintf "%d has a phrase" n)
        true
        (String.length (Spindle.Status.reason st) > 0))
    Spindle.Status.all;
  Alcotest.(check bool)
    "by number" true
    (Spindle.Status.equal (`Code 409) `Conflict);
  match
    Spindle.Refusal.Code.status
      (Spindle.Refusal.Code.make "c" ~status:(`Code 409) ~doc:"d")
  with
  | `Conflict -> ()
  | _ -> Alcotest.fail "a code declared by number keeps the number's spelling"

let test_an_app_lists_its_routes () =
  let signed_out = code "signed_out" `Unauthorized in
  let session =
    Spindle.Dep.credential ~scheme:"session"
      (Spindle.Cookie.optional
         (Spindle.Cookie.named "session" Spindle.Codec.string)
      |> Spindle.Dep.map (Option.to_result ~none:())
      |> Spindle.Dep.map
           (Result.map_error (fun () ->
                Spindle.Refusal.make signed_out "Sign in."))
      |> Spindle.Dep.join ~refuses:[ signed_out ])
  in
  let item =
    Spindle.post ~summary:"Add an item" ~tags:[ "orders" ]
      ~meta:Spindle.Meta.(empty |> add rate_limit 10)
      ~refuses:[ gone ]
      Spindle.Path.(s "orders" / order_id / s "items")
      (Spindle.Returns.json ~status:`Created greeting_json)
      (let+ _ = Spindle.param order_id
       and+ _ = session
       and+ _ = Spindle.Query.optional "page" Spindle.Codec.int
       and+ g = Spindle.json greeting_json in
       Ok g)
  in
  let opaque =
    Spindle.get
      Spindle.Path.(s "anything")
      Spindle.Returns.response
      (Spindle.Dep.map (fun _ -> Ok (Spindle.Response.make "")) Spindle.request)
  in
  match Spindle.App.routes (Spindle.Test.app [ item; opaque ]) with
  | [ i; o ] ->
      check_string "the method and pattern" "POST /orders/{order_id}/items"
        (Spindle.Meth.to_string i.meth ^ " " ^ i.pattern);
      Alcotest.(check (list string))
        "the path's parameters, typed" [ "order_id: integer" ]
        (List.map
           (fun (p : Spindle.Route.param) ->
             p.name ^ ": "
             ^
             match p.shape with
             | Spindle.Codec.Integer -> "integer"
             | _ -> "?")
           i.params);
      Alcotest.(check (list string))
        "its codes: its own and its inputs'"
        [ "gone"; "signed_out"; "unsupported_media_type" ]
        (List.map Spindle.Refusal.Code.name i.codes);
      Alcotest.(check (list string))
        "the credential it takes" [ "session" ]
        (List.map (fun (c : Spindle.Dep.credential) -> c.scheme) i.credentials);
      Alcotest.(check (option string))
        "what it says of itself" (Some "Add an item")
        (Spindle.Meta.find Spindle.Meta.summary i.meta);
      Alcotest.(check (option int))
        "and a package's own" (Some 10)
        (Spindle.Meta.find rate_limit i.meta);
      Alcotest.(check bool) "says all it reads" false i.opaque;
      Alcotest.(check bool) "unlike one that reads the request" true o.opaque;
      let printed = Format.asprintf "%a" Spindle.Route.pp_info i in
      List.iter
        (fun sub -> Alcotest.(check bool) sub true (contains ~sub printed))
        [
          "POST /orders/{order_id}/items  -- Add an item";
          "query page?: integer";
          "cookie session?: string";
          "body greeting";
          "201 greeting";
          "410 gone";
          "credentials: session";
        ]
  | l -> Alcotest.failf "expected two routes, got %d" (List.length l)

(* ------------------------------------------------------------------ *)
(* Health *)

let probes checks = Spindle.Test.app (Spindle.Health.routes checks)

(* Liveness asks nothing of what the server depends on: a failed probe is a
   restart, and a restart mends no database. *)
let test_liveness_runs_no_check () =
  Eio_main.run @@ fun _env ->
  let asked = ref 0 in
  let down =
    Spindle.Health.check "db" (fun () ->
        incr asked;
        Error "down")
  in
  let r = Spindle.Test.call (probes [ down ]) `GET "/livez" in
  check_status "alive" 200 r.status;
  check_string "says so" "ok" r.body;
  check_int "and asked nothing" 0 !asked

let test_ready_when_every_check_passes () =
  Eio_main.run @@ fun _env ->
  let up name = Spindle.Health.check name (fun () -> Ok ()) in
  let r = Spindle.Test.call (probes [ up "db"; up "cache" ]) `GET "/readyz" in
  check_status "ready" 200 r.status;
  check_string "says so" "ok" r.body

(* The refusal names the checks that failed, and why is for the log -- as
   degraded, never as our bug. *)
let test_not_ready_names_what_failed () =
  Eio_main.run @@ fun _env ->
  let r = ref None in
  let lines =
    captured (fun () ->
        r :=
          Some
            (Spindle.Test.call
               (probes
                  [
                    Spindle.Health.check "db" (fun () ->
                        Error "password rejected");
                    Spindle.Health.check "cache" (fun () -> Ok ());
                  ])
               `GET "/readyz"))
  in
  match !r with
  | None -> Alcotest.fail "no answer"
  | Some r ->
      check_status "not ready" 503 r.status;
      check_string "names the one that failed"
        {|{"error":"not_ready","message":"Not ready: db."}|} r.body;
      Alcotest.(check bool)
        "and not why" false
        (contains ~sub:"password" r.body);
      Alcotest.(check bool)
        "why is a warning" true
        (List.exists
           (fun l ->
             contains ~sub:{|"level":"warn"|} l
             && contains ~sub:"db: password rejected" l)
           lines);
      Alcotest.(check bool)
        "and nothing is an error" false
        (List.exists (contains ~sub:{|"level":"error"|}) lines)

(* Something asks every few seconds, so a probe's access line is there at
   debug and buries nothing at info. *)
let test_a_probe_is_logged_at_debug () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and mono_clock = Eio.Stdenv.mono_clock env in
  let lines = ref [] in
  let at level =
    Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some level)
      ~out:(fun l -> lines := l :: !lines)
      ()
  in
  let port =
    serve ~sw ~net
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ~domains:1 ~clock:mono_clock
      (Spindle.Test.app (hello :: Spindle.Health.routes []))
  in
  let call path = ignore (call_on ~net ~clock:mono_clock ~port `GET path) in
  let logged sub = List.exists (contains ~sub) !lines in
  at Logs.Info;
  call "/livez";
  call "/hello/kim";
  Alcotest.(check bool)
    "a request is at info" true
    (logged {|"message":"GET /hello/kim 200"|});
  Alcotest.(check bool)
    "a probe is not" false
    (logged {|"message":"GET /livez 200"|});
  at Logs.Debug;
  call "/readyz";
  Alcotest.(check bool)
    "it is at debug" true
    (logged {|"message":"GET /readyz 200"|})

(* ------------------------------------------------------------------ *)
(* Broadcast and alarms *)

(* A depth below one would drop every reader at the first event. *)
let test_a_depth_below_one_is_refused () =
  List.iter
    (fun depth ->
      match Spindle.Broadcast.create ~depth () with
      | _ -> Alcotest.failf "a depth of %d was taken" depth
      | exception Invalid_argument _ -> ())
    [ 0; -1; min_int ];
  ignore
    (Spindle.Broadcast.create ~depth:1 () : (unit, unit) Spindle.Broadcast.t)

(* One reader keeps up and one does not: the one that does not is dropped
   once it is [depth] behind, is told so with a [None] after what it was
   queued, and is no longer among the subscribers. *)
let test_a_slow_subscriber_is_dropped () =
  Eio_main.run @@ fun _env ->
  let b = Spindle.Broadcast.create ~depth:2 () in
  let quick = Spindle.Broadcast.subscribe b ~topic:"t" "quick" in
  let slow = Spindle.Broadcast.subscribe b ~topic:"t" "slow" in
  let got = ref [] in
  List.iter
    (fun e ->
      Spindle.Broadcast.publish b ~topic:"t" e;
      match Spindle.Broadcast.next quick with
      | Some e -> got := e :: !got
      | None -> Alcotest.fail "the quick reader was dropped")
    [ "1"; "2"; "3" ];
  Alcotest.(check (list string))
    "the quick one saw everything" [ "1"; "2"; "3" ] (List.rev !got);
  Alcotest.(check (list string))
    "and is the only one left" [ "quick" ]
    (Spindle.Broadcast.subscribers b ~topic:"t");
  Alcotest.(check (list (option string)))
    "the slow one got what was queued, then was told -- and told again"
    [ Some "1"; Some "2"; None; None ]
    (List.init 4 (fun _ -> Spindle.Broadcast.next slow));
  Alcotest.(check (list string))
    "the topic lasts while it has a reader" [ "t" ]
    (Spindle.Broadcast.topics b);
  Spindle.Broadcast.unsubscribe b quick;
  Alcotest.(check (list string))
    "and goes with the last one" []
    (Spindle.Broadcast.topics b);
  Alcotest.(check (option string))
    "who is told, like one dropped" None
    (Spindle.Broadcast.next quick)

(* A line of an event stream ends at CRLF, LF or a lone CR, so a comment is
   split at every one of them, and no CR begins a line of its own. *)
let test_a_comment_is_split_at_every_line_end () =
  check_string "each line a comment" ": a\n: b\n: c\n: d\n\n"
    (Spindle.Event.to_string (Spindle.Event.comment "a\r\nb\rc\nd"))

(* An id is one line a browser sends back as it was, so an event whose id
   holds a line break or a NUL sends nothing rather than something broken. *)
let test_an_id_is_one_line () =
  let n : (int, some_stream) Spindle.Event.kind =
    Spindle.Event.json "n" Wiretype.int
  in
  List.iter
    (fun id ->
      check_string
        (Printf.sprintf "%S sends nothing" id)
        ""
        (Spindle.Event.to_string (Spindle.Event.make ~id n 1)))
    [ "a\nb"; "a\rb"; "a\000b" ]

(* A name is the rest of its line and a retry is digits, so a name holding
   a break, or a negative retry, sends nothing rather than something a
   browser reads as another field, or ignores. *)
let test_a_name_is_one_line_and_a_retry_is_digits () =
  let broken : (int, some_stream) Spindle.Event.kind =
    Spindle.Event.json "a\nid: 7" Wiretype.int
  in
  check_string "a broken name sends nothing" ""
    (Spindle.Event.to_string (Spindle.Event.make broken 1));
  check_string "a negative retry sends nothing" ""
    (Spindle.Event.to_string (Spindle.Event.retry (-1)));
  check_string "a retry of none is one" "retry: 0\n\n"
    (Spindle.Event.to_string (Spindle.Event.retry 0))

(* On virtual time, whose timers can be counted: once the last wake-up has
   come, nothing may be left scheduled -- not the superseded one, set to
   sleep far past the one that replaced it, and not the cancelled one, due
   before it. *)
let test_an_alarm_set_again_supersedes () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#mono_clock in
  let fired = ref [] and last, came = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
      let alarms =
        Spindle.Alarm.create
          ~background:(Spindle.Background.create ~sw)
          ~mono_clock:clock ()
      in
      let set key in_ms name =
        Spindle.Alarm.set alarms ~key ~in_ms ~what:name (fun () ->
            fired := name :: !fired;
            ignore (Eio.Promise.try_resolve came () : bool))
      in
      set "k" 60_000 "first";
      set "gone" 10 "gone";
      set "k" 20 "second";
      Spindle.Alarm.cancel alarms ~key:"gone";
      Eio.Promise.await last;
      Alcotest.(check bool)
        "and no fiber left asleep" false
        (Eio_mock.Clock.Mono.try_advance clock));
  Alcotest.(check (list string))
    "only the last set, and nothing cancelled" [ "second" ] !fired

(* A key set on one domain and again on others leaves the last set to fire:
   from a domain with a switch of Spindle's the wake-up sleeps there, from
   one without it is posted. The superseded are due far past it; that a
   superseded wake-up never fires is the virtual-time case's, above. *)
let test_an_alarm_set_from_several_domains_fires_once () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let domain_mgr = Eio.Stdenv.domain_mgr env
  and clock = Eio.Stdenv.mono_clock env in
  let alarms =
    Spindle.Alarm.create
      ~background:(Spindle.Background.create ~sw)
      ~mono_clock:clock ()
  in
  let fired = Atomic.make [] and last, came = Eio.Promise.create () in
  let rec note name =
    let before = Atomic.get fired in
    if not (Atomic.compare_and_set fired before (name :: before)) then note name
  in
  let set in_ms name =
    Spindle.Alarm.set alarms ~key:"k" ~in_ms ~what:name (fun () ->
        note name;
        ignore (Eio.Promise.try_resolve came () : bool))
  in
  set 3_600_000 "here";
  Eio.Domain_manager.run domain_mgr (fun () -> set 1_800_000 "posted");
  Eio.Domain_manager.run domain_mgr (fun () ->
      Eio.Switch.run @@ fun sw ->
      Spindle.Local.within ~sw @@ fun () ->
      set 0 "local";
      Eio.Promise.await last);
  Alcotest.(check (list string))
    "only the last set" [ "local" ] (Atomic.get fired)

(* A subscriber on one domain hears what another published; and two
   domains publishing at once to a subscriber that never reads drop it
   exactly once, tell it exactly once, and wait for nobody. *)
let test_an_event_reaches_every_domain () =
  Eio_main.run @@ fun env ->
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let b = Spindle.Broadcast.create ~depth:16 () in
  let slow = Spindle.Broadcast.subscribe b ~topic:"t" "slow" in
  let listening, listen = Eio.Promise.create () in
  let heard = ref None in
  Eio.Fiber.both
    (fun () ->
      heard :=
        Eio.Domain_manager.run domain_mgr (fun () ->
            let quick = Spindle.Broadcast.subscribe b ~topic:"t" "quick" in
            Eio.Promise.resolve listen ();
            Spindle.Broadcast.next quick))
    (fun () ->
      Eio.Promise.await listening;
      Spindle.Broadcast.publish b ~topic:"t" "hello");
  Alcotest.(check (option string)) "heard" (Some "hello") !heard;
  let flood () =
    Eio.Domain_manager.run domain_mgr (fun () ->
        for i = 1 to 1000 do
          Spindle.Broadcast.publish b ~topic:"t" (string_of_int i)
        done)
  in
  Eio.Fiber.both flood flood;
  let rec queued n =
    match Spindle.Broadcast.next slow with
    | Some _ -> queued (n + 1)
    | None -> n
  in
  check_int "the slow one got a depth of events" 16 (queued 0);
  Alcotest.(check (option string))
    "then was told, and told again" None
    (Spindle.Broadcast.next slow)

(* ------------------------------------------------------------------ *)
(* Codecs *)

(* A codec, the text it reads and the text it refuses. *)
type codec_case =
  | Codec_case : {
      name : string;
      codec : 'a Spindle.Codec.t;
      reads : string list;
      refuses : string list;
    }
      -> codec_case

let codec_cases =
  let case name codec reads refuses =
    Codec_case { name; codec; reads; refuses }
  in
  [
    case "int" Spindle.Codec.int [ "42"; "-7"; "0" ]
      [ ""; "0x1f"; "1_000"; "+3"; "1e3"; " 4"; "99999999999999999999" ];
    case "float" Spindle.Codec.float
      [ "21"; "-7.5"; "0.1"; "1e3"; "2.5E-4"; "-0"; "1e308" ]
      [
        "";
        ".5";
        "5.";
        "+3";
        "1_000";
        "0x1p3";
        "inf";
        "nan";
        "1e";
        "1e400";
        " 4";
        "4 ";
      ];
    case "uuid" Spindle.Codec.uuid
      [
        "0190f8a4-6d2e-7c3b-9a1f-2b4c6d8e0f12";
        "0190F8A4-6D2E-7C3B-9A1F-2B4C6D8E0F12";
        "00000000-0000-0000-0000-000000000000";
      ]
      [
        "";
        "not-a-uuid";
        "0190f8a4-6d2e-7c3b-9a1f";
        "0190f8a46d2e7c3b9a1f2b4c6d8e0f12";
      ];
    case "date" Spindle.Codec.date
      [ "2026-10-08"; "2024-02-29" ]
      [
        "";
        "2026-02-30";
        "2025-02-29";
        "2026-10-8";
        "08/10/2026";
        "2026-10-08T00:00:00Z";
      ];
    case "instant" Spindle.Codec.instant
      [
        "2026-10-08T12:00:00.000Z";
        "2026-10-08T13:00:00+01:00";
        "2026-10-08T12:00:00Z";
      ]
      [ ""; "2026-10-08"; "yesterday"; "2026-10-08 12:00:00"; "1759924800000" ];
    case "int64" Spindle.Codec.int64
      [ "9223372036854775807"; "-9223372036854775808" ]
      [ "9223372036854775808"; "+1"; "0x1"; "" ];
    case "media_type" Spindle.Codec.media_type
      [ "text/html; charset=utf-8"; "application/json" ]
      [ "text"; "text/"; "/html"; "" ];
    case "credentials" Spindle.Codec.credentials
      [ "Bearer abc.def"; "Basic dXNlcjpwYXNz" ]
      [ ""; "Bearer abc def" ];
    case "accept" Spindle.Codec.accept
      [ "text/html, application/json;q=0.9"; "*/*" ]
      [ "text/html;q=2"; "text/html;q=abc" ];
    case "weighted" Spindle.Codec.weighted
      [ "gzip, br;q=0.5"; "en-GB, en;q=0.8" ]
      [ "gzip;q=1.5"; "gzip;q=x" ];
    case "cache_control" Spindle.Codec.cache_control
      [ "no-cache"; "max-age=60, private" ]
      [ {|max-age="60|}; "=60" ];
    case "forwarded" Spindle.Codec.forwarded
      [ "for=192.0.2.60;proto=https;by=203.0.113.43"; {|for="[2001:db8::1]"|} ]
      [ "=x"; "for=" ];
    case "structured_item" Spindle.Codec.structured_item
      [ "1"; "?1"; {|"hello"|}; "token;a=1" ]
      [ {|"unterminated|}; "1.2345" ];
    case "structured_list" Spindle.Codec.structured_list [ "a, b, (c d)" ]
      [ "a,"; "(a" ];
    case "structured_dictionary" Spindle.Codec.structured_dictionary
      [ "a=1, b, c=?0" ] [ "a="; "A=1" ];
  ]

(* What a codec reads, it prints as text it reads again to the same
   printing; what it refuses, it refuses. *)
let test_a_codec_reads_and_refuses_as_its_grammar () =
  List.iter
    (fun (Codec_case { name; codec; reads; refuses }) ->
      List.iter
        (fun text ->
          match Spindle.Codec.parse codec text with
          | None -> Alcotest.failf "%s refused %S" name text
          | Some v -> (
              let printed = Spindle.Codec.print codec v in
              match Spindle.Codec.parse codec printed with
              | Some again ->
                  check_string
                    (Printf.sprintf "%s prints %S as it reads back" name text)
                    printed
                    (Spindle.Codec.print codec again)
              | None ->
                  Alcotest.failf "%s printed %S as %S, which it refuses" name
                    text printed))
        reads;
      List.iter
        (fun text ->
          Alcotest.(check bool)
            (Printf.sprintf "%s refuses %S" name text)
            true
            (Option.is_none (Spindle.Codec.parse codec text)))
        refuses)
    codec_cases

(* Every finite float prints as text the codec reads back as the same
   float, so a value an application writes into a link is the one it gets. *)
let test_a_float_comes_back_as_itself =
  QCheck.Test.make ~count:1000 ~name:"a float comes back as itself" QCheck.float
    (fun v ->
      QCheck.assume (Float.is_finite v);
      match
        Spindle.Codec.parse Spindle.Codec.float
          (Spindle.Codec.print Spindle.Codec.float v)
      with
      | Some again -> Float.equal again v
      | None -> false)

(* A header read by a codec answers what it read, and one it refuses is
   [invalid] at its place -- but for whitespace around it, which is no part
   of a field's value (RFC 9110 §5.5). *)
let test_a_header_is_read_by_its_codec () =
  List.iter
    (fun (Codec_case { name; codec; reads; refuses }) ->
      let a =
        Spindle.Test.app
          [
            Spindle.get
              Spindle.Path.(s "h")
              Spindle.Returns.text
              (let+ v = Spindle.Header.required "x-value" codec in
               Ok (Spindle.Codec.print codec v));
          ]
      in
      let call text =
        Spindle.Test.call a `GET "/h" ~headers:[ ("x-value", text) ]
      in
      List.iter
        (fun text ->
          check_status
            (Printf.sprintf "%s reads %S" name text)
            200 (call text).status)
        reads;
      List.iter
        (fun text ->
          if String.equal (String.trim text) text && not (String.equal text "")
          then (
            let r = call text in
            check_status (Printf.sprintf "%s refuses %S" name text) 400 r.status;
            Alcotest.(check bool)
              "at its header" true
              (contains ~sub:"header.x-value" r.body)))
        refuses)
    codec_cases

let () =
  Alcotest.run "web"
    [
      ( "routes",
        [
          Alcotest.test_case "a path parameter reaches the handler" `Quick
            test_path_parameter_reaches_the_handler;
          Alcotest.test_case "two routes claiming one path are refused" `Quick
            test_two_routes_claiming_one_path_are_refused;
          Alcotest.test_case "one path under two methods" `Quick
            test_the_same_path_under_two_methods_is_fine;
          Alcotest.test_case "wrong method is 405 with Allow" `Quick
            test_wrong_method_is_405_with_allow;
          Alcotest.test_case "unknown path is 404, or the not-found answer"
            `Quick test_unknown_path_is_404_or_the_not_found_answer;
          Alcotest.test_case "HEAD is GET without the body" `Quick
            test_head_is_get_without_the_body;
          Alcotest.test_case "nothing is an answer" `Quick
            test_nothing_is_an_answer;
          Alcotest.test_case "a trailing slash is another path" `Quick
            test_a_trailing_slash_is_another_path;
          Alcotest.test_case "a header the framework writes is the route's bug"
            `Quick test_a_header_the_framework_writes_is_the_routes_bug;
          Alcotest.test_case "the root answers /" `Quick
            test_the_root_answers_slash;
          Alcotest.test_case "a segment is decoded" `Quick
            test_a_segment_is_decoded;
        ] );
      ( "paths",
        [
          Alcotest.test_case "a literal beats a parameter, in any order" `Quick
            test_a_literal_beats_a_parameter_in_any_order;
          Alcotest.test_case "a parameter that declines is asked first" `Quick
            test_a_parameter_that_declines_is_asked_first;
          Alcotest.test_case "routes that could both answer are refused" `Quick
            test_routes_that_could_both_answer_are_refused;
          Alcotest.test_case "a parameter its path lacks is refused" `Quick
            test_a_parameter_its_path_lacks_is_refused;
          Alcotest.test_case "a parameter behind a bind is found when it runs"
            `Quick test_a_parameter_behind_a_bind_is_found_when_it_runs;
          Alcotest.test_case "a bad parameter is a problem" `Quick
            test_a_bad_parameter_is_a_problem;
          Alcotest.test_case "a custom segment: a problem, or not the route"
            `Quick test_a_custom_segment_is_a_problem_or_not_the_route;
          QCheck_alcotest.to_alcotest test_a_printed_path_parses_back;
          QCheck_alcotest.to_alcotest test_the_table_answers_as_the_rule;
          Alcotest.test_case "a path prints only from its own parameters" `Quick
            test_a_path_prints_only_from_its_own_parameters;
          Alcotest.test_case "the rest of a path is its segments" `Quick
            test_the_rest_of_a_path_is_its_segments;
          Alcotest.test_case "the rest ranks last at any depth" `Quick
            test_the_rest_ranks_last_at_any_depth;
          Alcotest.test_case "a rest takes only what no route names" `Quick
            test_a_rest_takes_only_what_no_route_names;
          Alcotest.test_case "a rest before the end is refused" `Quick
            test_a_rest_before_the_end_is_refused;
          Alcotest.test_case "the rest prints and parses back" `Quick
            test_the_rest_prints_and_parses_back;
          QCheck_alcotest.to_alcotest test_a_printed_rest_parses_back;
          Alcotest.test_case "int64, and a custom kind, read as sentences"
            `Quick test_int64_and_a_custom_kind_read_as_sentences;
        ] );
      ( "a streamed body",
        [
          Alcotest.test_case "it is read in parts" `Quick
            test_a_streamed_body_is_read_in_parts;
          Alcotest.test_case "a read after its handler reads nothing" `Quick
            test_a_body_read_after_its_handler_reads_nothing;
          Alcotest.test_case "a route reads one body" `Quick
            test_a_route_reads_one_body;
        ] );
      ( "static files",
        [
          Alcotest.test_case "a site answers by its three rules" `Quick
            test_a_site_answers_by_its_three_rules;
          Alcotest.test_case "with nothing named, it serves its files" `Quick
            test_a_site_with_nothing_named_serves_its_files;
          Alcotest.test_case "a directory is read when the server starts" `Quick
            test_a_directory_is_read_when_the_server_starts;
          Alcotest.test_case "a site under a prefix" `Quick
            test_a_site_under_a_prefix;
          Alcotest.test_case "a file is typed, and cached by its prefix" `Quick
            test_a_file_is_typed_and_cached_by_its_prefix;
          Alcotest.test_case "a matching tag is 304" `Quick
            test_a_matching_tag_is_304;
          Alcotest.test_case "a site that cannot be served is refused" `Quick
            test_a_site_that_cannot_be_served_is_refused;
          Alcotest.test_case "a static file answers a range" `Quick
            test_a_static_file_answers_a_range;
        ] );
      ( "files",
        [
          Alcotest.test_case "a file is served from disk as it is" `Quick
            test_a_file_is_served_from_disk_as_it_is;
          Alcotest.test_case "files never leave their directory" `Quick
            test_files_never_leave_their_directory;
          Alcotest.test_case "a file answers its conditions and ranges" `Quick
            test_a_file_answers_its_conditions_and_ranges;
          Alcotest.test_case "a download is named" `Quick
            test_a_download_is_named;
          Alcotest.test_case "a file replaced before its body sends nothing"
            `Quick test_a_file_replaced_before_its_body_sends_nothing;
          Alcotest.test_case "a directory not there is refused at start" `Quick
            test_a_directory_not_there_is_refused_at_start;
        ] );
      ( "bodies",
        [
          Alcotest.test_case "an absent body is {}" `Quick
            test_absent_body_reads_as_an_empty_object;
          Alcotest.test_case "a body is decoded" `Quick test_body_is_decoded;
          Alcotest.test_case "a malformed body is a sentence" `Quick
            test_malformed_body_is_a_sentence_without_its_detail;
          Alcotest.test_case "a raise is 500 and says nothing of it" `Quick
            test_a_raise_is_500_and_says_nothing_of_it;
        ] );
      ( "middleware",
        [
          Alcotest.test_case "runs in the order listed" `Quick
            test_middleware_runs_in_the_order_listed;
          Alcotest.test_case "may answer alone" `Quick
            test_middleware_may_answer_alone;
          Alcotest.test_case "a raise is 500" `Quick
            test_a_middleware_that_raises_is_500;
          Alcotest.test_case "can ask the route" `Quick
            test_middleware_can_ask_the_route;
          Alcotest.test_case "headers reach every answer" `Quick
            test_headers_reach_every_answer;
          Alcotest.test_case "an answer of its own is in the access log" `Quick
            (test_a_middleware_answer_is_in_the_access_log 1);
        ] );
      ( "dependencies",
        [
          Alcotest.test_case "the first refusal stops the list" `Quick
            test_dependencies_stop_at_the_first_refusal;
          Alcotest.test_case "query, header, cookie and clock" `Quick
            test_query_header_cookie_and_clock;
          Alcotest.test_case "a default stands in for an absent input" `Quick
            test_a_default_stands_in_for_an_absent_input;
          Alcotest.test_case "a refusal before the body never reads it" `Quick
            test_a_refusal_before_the_body_never_reads_it;
          Alcotest.test_case "a bind after the body reads it" `Quick
            test_bind_after_the_body_reads_it;
          Alcotest.test_case "a dependency says what it reads" `Quick
            test_a_dependency_says_what_it_reads;
          Alcotest.test_case "a dependency runs once per request" `Quick
            test_a_dependency_runs_once_per_request;
          Alcotest.test_case "uncached runs at every use" `Quick
            test_uncached_runs_at_every_use;
          Alcotest.test_case "a body dependency is read once" `Quick
            test_a_body_dependency_is_read_once;
          Alcotest.test_case "an input read twice is one input" `Quick
            test_an_input_read_twice_is_one_input;
          Alcotest.test_case "a bind shares what it names" `Quick
            test_a_bind_shares_what_it_names;
          Alcotest.test_case "a codec reads and refuses as its grammar" `Quick
            test_a_codec_reads_and_refuses_as_its_grammar;
          Alcotest.test_case "a header is read by its codec" `Quick
            test_a_header_is_read_by_its_codec;
          QCheck_alcotest.to_alcotest test_a_float_comes_back_as_itself;
        ] );
      ( "cookies",
        [
          Alcotest.test_case "Secure except on loopback" `Quick
            test_cookie_is_secure_except_on_loopback;
          Alcotest.test_case "clearing one" `Quick test_clearing_a_cookie;
          Alcotest.test_case "a key is made from a secret" `Quick
            test_a_key_is_made_from_a_secret;
          Alcotest.test_case "a signed cookie reads only as it was made" `Quick
            test_a_signed_cookie_reads_only_as_it_was_made;
          Alcotest.test_case "an encrypted cookie reads only as it was made"
            `Quick test_an_encrypted_cookie_reads_only_as_it_was_made;
          Alcotest.test_case "a sealed cookie ages" `Quick
            test_a_sealed_cookie_ages;
          Alcotest.test_case "a session is kept on the server" `Quick
            test_a_session_is_kept_on_the_server;
          Alcotest.test_case "a session ends by its limits" `Quick
            test_a_session_ends_by_its_limits;
          Alcotest.test_case "refuses what it cannot hold" `Quick
            test_a_cookie_refuses_what_it_cannot_hold;
          QCheck_alcotest.to_alcotest test_an_encoded_cookie_carries_any_text;
          Alcotest.test_case "one not encoded by us is a problem" `Quick
            test_a_cookie_not_encoded_by_us_is_a_problem;
        ] );
      ( "forgery",
        [
          Alcotest.test_case "a request from another site is refused" `Quick
            test_a_request_from_another_site_is_refused;
          Alcotest.test_case "a trusted origin, a trusted proxy" `Quick
            test_a_trusted_origin_and_a_trusted_proxy_pass;
          Alcotest.test_case "JSON is only JSON" `Quick test_json_is_only_json;
        ] );
      ( "tests that keep cookies and read a stream",
        [
          Alcotest.test_case "a test browser keeps what the app set" `Quick
            test_a_test_browser_keeps_what_the_app_set;
          Alcotest.test_case "a test reads a stream that never ends" `Quick
            test_a_test_reads_a_stream_that_never_ends;
        ] );
      ( "event streams",
        [
          Alcotest.test_case "an event stream reads as the standard says" `Quick
            test_an_event_stream_reads_as_the_standard_says;
          Alcotest.test_case "the client reads as it arrives" `Quick
            test_the_client_reads_as_it_arrives;
        ] );
      ( "rate limits",
        [
          Alcotest.test_case "a burst is its own figure" `Quick
            test_a_burst_is_its_own_figure;
          Alcotest.test_case "a limit refuses past its rate" `Quick
            test_a_limit_refuses_past_its_rate;
        ] );
      ( "compression",
        [
          Alcotest.test_case "an answer is compressed where it may be" `Quick
            test_an_answer_is_compressed_where_it_may_be;
          Alcotest.test_case "a stream compresses in process" `Quick
            test_a_stream_compresses_in_process;
          Alcotest.test_case "a static file's precompressed sibling is served"
            `Quick test_a_static_file's_precompressed_sibling_is_served;
          Alcotest.test_case "a file's precompressed sibling is served" `Quick
            test_a_file's_precompressed_sibling_is_served;
        ] );
      ( "cors",
        [
          Alcotest.test_case "a preflight is the framework's" `Quick
            test_a_preflight_is_the_framework's;
          Alcotest.test_case "an answer says who may read it" `Quick
            test_an_answer_says_who_may_read_it;
          Alcotest.test_case "an allowed origin may write" `Quick
            test_an_allowed_origin_may_write;
        ] );
      ( "forms",
        [
          Alcotest.test_case "a form's fields are typed inputs" `Quick
            test_a_form's_fields_are_typed_inputs;
          Alcotest.test_case "a form is read once, and only as a form" `Quick
            test_a_form_is_read_once_and_only_as_a_form;
          Alcotest.test_case "a form is described" `Quick
            test_a_form_is_described;
          Alcotest.test_case "urlencoded reads as a browser writes" `Quick
            test_urlencoded_reads_as_a_browser_writes;
          Alcotest.test_case "an upload is read a part at a time" `Quick
            test_an_upload_is_read_a_part_at_a_time;
          Alcotest.test_case "a form's files are inputs" `Quick
            test_a_form's_files_are_inputs;
        ] );
      ( "logging",
        [
          Alcotest.test_case "a line is one JSON object" `Quick
            test_a_line_is_one_json_object;
          Alcotest.test_case "a domain that logs can end" `Quick
            test_a_domain_that_logs_can_end;
          Alcotest.test_case "every line reaches stderr whole" `Quick
            test_every_line_reaches_stderr_whole;
          Alcotest.test_case "a printer that logs writes its own line" `Quick
            test_a_printer_that_logs_writes_its_own_line;
          Alcotest.test_case "levels are read from a spec" `Quick
            test_levels_are_read_from_a_spec;
          Alcotest.test_case "the wire is not raised by the everything level"
            `Quick test_the_wire_is_not_raised_by_the_everything_level;
          Alcotest.test_case "the request id crosses to a thread" `Quick
            test_the_request_id_crosses_to_a_thread;
          Alcotest.test_case "a request joins the trace it was sent" `Quick
            test_a_request_joins_the_trace_it_was_sent;
          Alcotest.test_case "a line carries the trace" `Quick
            test_a_line_carries_the_trace;
          Alcotest.test_case "posted work keeps the trace" `Quick
            test_posted_work_keeps_the_trace;
          Alcotest.test_case "a call carries the trace" `Quick
            test_a_call_carries_the_trace;
          Alcotest.test_case "a kept trace records its spans" `Quick
            test_a_kept_trace_records_its_spans;
          Alcotest.test_case "a trace is kept whole or not at all" `Quick
            test_a_trace_is_kept_whole_or_not_at_all;
          Alcotest.test_case "a tracestate is passed on" `Quick
            test_a_tracestate_is_passed_on;
          Alcotest.test_case "a request and its call are one trace" `Quick
            test_a_request_and_its_call_are_one_trace;
          Alcotest.test_case "spans reach a collector" `Quick
            test_spans_reach_a_collector;
          Alcotest.test_case
            "a whole batch is sent without waiting for the tick" `Slow
            test_a_whole_batch_is_sent_without_waiting_for_the_tick;
          Alcotest.test_case "no header value reaches the log" `Quick
            test_no_header_value_reaches_the_log;
          Alcotest.test_case "request ids are distinct across domains" `Quick
            test_request_ids_are_distinct_across_domains;
        ] );
      ( "client",
        [
          Alcotest.test_case "answers, times out, and reports" `Quick
            (test_the_client_answers_times_out_and_reports 1);
          Alcotest.test_case "a failed handshake leaves no socket" `Quick
            test_a_failed_handshake_leaves_no_socket;
          Alcotest.test_case "a refused address leaves no socket" `Quick
            test_a_refused_address_leaves_no_socket;
        ] );
      ( "the edges",
        [
          Alcotest.test_case "a forwarded address needs a trusted proxy" `Quick
            (test_a_forwarded_address_is_believed_only_from_a_trusted_proxy 1);
          Alcotest.test_case "forwarded is believed where it is named" `Quick
            (test_forwarded_is_believed_where_it_is_named 1);
          Alcotest.test_case "every serving domain raises its minor heap" `Quick
            test_every_serving_domain_raises_its_minor_heap;
          Alcotest.test_case "a limit out of range is refused" `Quick
            test_a_limit_out_of_range_is_refused;
          Alcotest.test_case "an IPv4 peer through the IPv6 wildcard" `Quick
            (test_an_ipv4_peer_through_the_ipv6_wildcard 1);
          Alcotest.test_case "the access log says what went out" `Quick
            (test_the_access_log_says_what_went_out 1);
          Alcotest.test_case "a body past the limit is 413" `Quick
            (test_a_body_past_the_limit_is_413 1);
          Alcotest.test_case "HEAD says how long GET would be" `Quick
            (test_head_says_how_long_get_would_be 1);
          Alcotest.test_case "a stop lets answers finish" `Quick
            (test_a_stop_lets_answers_finish 1);
          Alcotest.test_case "a drain that runs out ends on time" `Quick
            (test_a_drain_that_runs_out_ends_on_time 1);
          Alcotest.test_case "a signal stops the server" `Quick
            test_a_signal_stops_the_server;
          Alcotest.test_case "a background raise is logged, not raised" `Quick
            test_a_background_raise_is_logged_not_raised;
          Alcotest.test_case "past the cap a connection waits" `Quick
            (test_past_the_cap_a_connection_waits 1);
          Alcotest.test_case "a client that never reads frees its slot" `Quick
            (test_a_client_that_never_reads_frees_its_slot 1);
          Alcotest.test_case "the send limit is on a stop, not a length" `Quick
            (test_the_send_limit_is_on_a_stop_not_a_length 1);
          Alcotest.test_case "a stream ends when its client stops reading"
            `Quick
            (test_a_stream_ends_when_its_client_stops_reading 1);
          Alcotest.test_case "a jumping clock moves no duration" `Quick
            (test_a_jumping_clock_moves_no_duration 1);
          Alcotest.test_case "localhost is both loopbacks" `Quick
            (test_localhost_is_both_loopbacks 1);
          Alcotest.test_case "a wildcard listens on every interface" `Quick
            (test_a_wildcard_listens_on_every_interface 1);
          Alcotest.test_case "an address is exactly that one" `Quick
            (test_an_address_is_exactly_that_one 1);
          Alcotest.test_case "a stream ends when its client goes" `Quick
            (test_a_stream_ends_when_its_client_goes 1);
          Alcotest.test_case "https is never spoken as plain http" `Quick
            (test_https_is_never_spoken_as_plain_http 1);
          Alcotest.test_case "a server answers on every domain it was given"
            `Quick test_a_server_answers_on_every_domain_it_was_given;
          Alcotest.test_case "every core, unasked" `Quick
            test_every_core_unasked;
          Alcotest.test_case "work runs where it was caused" `Quick
            test_work_runs_where_it_was_caused;
          Alcotest.test_case "a pretty line reads" `Quick
            test_a_pretty_line_reads;
          Alcotest.test_case "blocking carries the request, refuses an effect"
            `Quick test_blocking_carries_the_request_and_refuses_an_effect;
        ] );
      ( "the edges, on four domains",
        [
          Alcotest.test_case "the client answers times out and reports" `Quick
            (test_the_client_answers_times_out_and_reports 4);
          Alcotest.test_case
            "a forwarded address is believed only from a trusted proxy" `Quick
            (test_a_forwarded_address_is_believed_only_from_a_trusted_proxy 4);
          Alcotest.test_case "a body past the limit is 413" `Quick
            (test_a_body_past_the_limit_is_413 4);
          Alcotest.test_case "head says how long get would be" `Quick
            (test_head_says_how_long_get_would_be 4);
          Alcotest.test_case "a middleware answer is in the access log" `Quick
            (test_a_middleware_answer_is_in_the_access_log 4);
          Alcotest.test_case "the access log says what went out" `Quick
            (test_the_access_log_says_what_went_out 4);
          Alcotest.test_case "an ipv4 peer through the ipv6 wildcard" `Quick
            (test_an_ipv4_peer_through_the_ipv6_wildcard 4);
          Alcotest.test_case "a drain that runs out ends on time" `Quick
            (test_a_drain_that_runs_out_ends_on_time 4);
          Alcotest.test_case "a stop lets answers finish" `Quick
            (test_a_stop_lets_answers_finish 4);
          Alcotest.test_case "past the cap a connection waits" `Quick
            (test_past_the_cap_a_connection_waits 4);
          Alcotest.test_case "localhost is both loopbacks" `Quick
            (test_localhost_is_both_loopbacks 4);
          Alcotest.test_case "a wildcard listens on every interface" `Quick
            (test_a_wildcard_listens_on_every_interface 4);
          Alcotest.test_case "an address is exactly that one" `Quick
            (test_an_address_is_exactly_that_one 4);
          Alcotest.test_case "a stream ends when its client goes" `Quick
            (test_a_stream_ends_when_its_client_goes 4);
          Alcotest.test_case "a client that never reads frees its slot" `Quick
            (test_a_client_that_never_reads_frees_its_slot 4);
          Alcotest.test_case "the send limit is on a stop, not a length" `Quick
            (test_the_send_limit_is_on_a_stop_not_a_length 4);
          Alcotest.test_case "a stream ends when its client stops reading"
            `Quick
            (test_a_stream_ends_when_its_client_stops_reading 4);
          Alcotest.test_case "a jumping clock moves no duration" `Quick
            (test_a_jumping_clock_moves_no_duration 4);
          Alcotest.test_case "https is never spoken as plain http" `Quick
            (test_https_is_never_spoken_as_plain_http 4);
        ] );
      ( "answers, codes and problems",
        [
          Alcotest.test_case "an answer encodes what the route returns" `Quick
            test_an_answer_encodes_what_the_route_returns;
          Alcotest.test_case "a page and text are their media types" `Quick
            test_a_page_and_text_are_their_media_types;
          Alcotest.test_case "what an endpoint sets goes only with Ok" `Quick
            test_what_an_endpoint_sets_goes_only_with_ok;
          Alcotest.test_case "a call after the answer changes nothing" `Quick
            test_a_call_after_the_answer_changes_nothing;
          Alcotest.test_case "serve refuses routes before it listens" `Quick
            test_serve_refuses_routes_before_it_listens;
          Alcotest.test_case "serve listens, and stops" `Quick
            test_serve_listens_and_stops;
          Alcotest.test_case "a code nobody declared is the route's bug" `Quick
            test_a_code_nobody_declared_is_the_routes_bug;
          Alcotest.test_case "a middleware's codes are declared" `Quick
            test_a_middlewares_codes_are_declared;
          Alcotest.test_case "a route answers the status it chose" `Quick
            test_a_route_answers_the_status_it_chose;
          Alcotest.test_case "a route's statuses are checked" `Quick
            test_a_routes_statuses_are_checked;
          Alcotest.test_case "every problem is told at once" `Quick
            test_every_problem_is_told_at_once;
          Alcotest.test_case "typed inputs" `Quick test_typed_inputs;
          Alcotest.test_case "a stream sends its declared events" `Quick
            test_a_stream_sends_its_declared_events;
        ] );
      ( "introspection",
        [
          Alcotest.test_case "a code means one thing" `Quick
            test_a_code_means_one_thing;
          Alcotest.test_case "a HEAD route is refused" `Quick
            test_a_head_route_is_refused;
          Alcotest.test_case "a body's own refusal is declared" `Quick
            test_a_bodys_own_refusal_is_declared;
          Alcotest.test_case "a status has one spelling" `Quick
            test_a_status_has_one_spelling;
          Alcotest.test_case "an app lists its routes" `Quick
            test_an_app_lists_its_routes;
        ] );
      ( "health",
        [
          Alcotest.test_case "liveness runs no check" `Quick
            test_liveness_runs_no_check;
          Alcotest.test_case "ready when every check passes" `Quick
            test_ready_when_every_check_passes;
          Alcotest.test_case "not ready names what failed" `Quick
            test_not_ready_names_what_failed;
          Alcotest.test_case "a probe is logged at debug" `Quick
            test_a_probe_is_logged_at_debug;
        ] );
      ( "metrics",
        [
          Alcotest.test_case "written as Prometheus reads them" `Quick
            test_metrics_are_written_as_prometheus_reads_them;
          Alcotest.test_case "every domain counts into one series" `Quick
            test_every_domain_counts_into_one_series;
          Alcotest.test_case "a metric that cannot be exposed is refused" `Quick
            test_a_metric_that_cannot_be_exposed_is_refused;
          Alcotest.test_case "a server counts its requests" `Quick
            test_a_server_counts_its_requests;
          Alcotest.test_case "guarded as a route is" `Quick
            test_metrics_are_guarded_as_a_route_is;
        ] );
      ( "broadcast and alarms",
        [
          Alcotest.test_case "a comment is split at every line end" `Quick
            test_a_comment_is_split_at_every_line_end;
          Alcotest.test_case "an id is one line" `Quick test_an_id_is_one_line;
          Alcotest.test_case "a name is one line, and a retry is digits" `Quick
            test_a_name_is_one_line_and_a_retry_is_digits;
          Alcotest.test_case "a slow subscriber is dropped" `Quick
            test_a_slow_subscriber_is_dropped;
          Alcotest.test_case "a depth below one is refused" `Quick
            test_a_depth_below_one_is_refused;
          Alcotest.test_case "an alarm set again supersedes" `Quick
            test_an_alarm_set_again_supersedes;
          Alcotest.test_case "an alarm set from several domains fires once"
            `Quick test_an_alarm_set_from_several_domains_fires_once;
          Alcotest.test_case "an event reaches every domain" `Quick
            test_an_event_reaches_every_domain;
        ] );
    ]
