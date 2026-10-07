(* What the server writes on a connection, read off a raw socket.

   Every case sends several requests down ONE connection, because that is
   where framing goes wrong: a server tested one request per connection
   cannot see a body left behind to be read as the next request, which is
   how the first of these went unnoticed. *)

open Spindle.Syntax

(* A code of the test's own, declared where a refusal is made from it. *)
let code name status =
  (* A 401 names how to authenticate, as every one must. *)
  let challenge =
    match status with `Unauthorized -> Some {|Test realm="t"|} | _ -> None
  in
  Spindle.Refusal.Code.make ?challenge name ~status ~doc:"A test's."

let name = Spindle.Path.str "name"

let hello =
  Spindle.get
    Spindle.Path.(s "hello" / name)
    Spindle.Returns.response
    (let+ name = Spindle.param name in
     Ok (Spindle.Response.make name))

let ignores_its_body =
  Spindle.post
    Spindle.Path.(s "ignore")
    Spindle.Returns.response
    (Spindle.Dep.return (Ok (Spindle.Response.make "ignored")))

let echo =
  Spindle.post
    Spindle.Path.(s "echo")
    Spindle.Returns.response
    (Spindle.Dep.map (fun b -> Ok (Spindle.Response.make b)) Spindle.body)

(* Reads its body as it arrives and says how many bytes came, answering a
   body it could not read as the framework would have. *)
let rec tally body bytes =
  match Spindle.Body.read body with
  | Ok (`Data s) -> tally body (bytes + String.length s)
  | Ok `End -> Ok (Spindle.Response.make (string_of_int bytes))
  | Error e -> Error (Spindle.Body.refusal e)

let upload =
  Spindle.post
    Spindle.Path.(s "upload")
    Spindle.Returns.response
    (let+ body = Spindle.body_stream ~max:1_000_000 () in
     tally body 0)

(* Reads one part and answers, leaving the rest to the loop. *)
let reads_a_part =
  Spindle.post
    Spindle.Path.(s "part")
    Spindle.Returns.response
    (let+ body = Spindle.body_stream ~max:1_000_000 () in
     match Spindle.Body.read body with
     | Ok (`Data s) -> Ok (Spindle.Response.make (String.make 1 s.[0]))
     | Ok `End -> Ok (Spindle.Response.make "")
     | Error e -> Error (Spindle.Body.refusal e))

(* Four domains unless told, as a server is run: the framework's own suites
   are where its state is proven safe from several. On [In_memory]'s virtual
   time; what it answers is [on_connection]'s, below. *)
let serve ~sw env ?(domains = 4) ?max_body ?max_header_bytes ?discard_limit
    ?body_budget ?stop ?drain_s served =
  let listening, connect = In_memory.listen () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains
        ~now:(fun () -> 0)
        ?max_body ?max_header_bytes ?discard_limit ?body_budget ?stop ?drain_s
        [ listening ] served;
      `Stop_daemon);
  connect

(* ------------------------------------------------------------------ *)
(* A client that reads exactly what came back *)

type answer = { status : int; headers : (string * string) list; body : string }

let header a name = List.assoc_opt name a.headers

let read_answer ?(head = false) r =
  let line = Eio.Buf_read.line r in
  let status = int_of_string (String.sub line 9 3) in
  let rec headers acc =
    match Eio.Buf_read.line r with
    | "" -> List.rev acc
    | l ->
        let i = String.index l ':' in
        headers
          (( String.lowercase_ascii (String.sub l 0 i),
             String.trim (String.sub l (i + 1) (String.length l - i - 1)) )
          :: acc)
  in
  let headers = headers [] in
  let body =
    if head || status < 200 || status = 204 || status = 304 then ""
    else
      match
        ( List.assoc_opt "content-length" headers,
          List.assoc_opt "transfer-encoding" headers )
      with
      | Some n, _ -> Eio.Buf_read.take (int_of_string n) r
      | None, Some _ ->
          let b = Buffer.create 64 in
          let rec chunks () =
            match int_of_string ("0x" ^ Eio.Buf_read.line r) with
            | 0 -> ignore (Eio.Buf_read.line r : string)
            | n ->
                Buffer.add_string b (Eio.Buf_read.take n r);
                ignore (Eio.Buf_read.line r : string);
                chunks ()
          in
          chunks ();
          Buffer.contents b
      | None, None -> ""
  in
  { status; headers; body }

let closed r =
  match Eio.Buf_read.ensure r 1 with
  | () -> false
  | exception End_of_file -> true
  | exception Eio.Io (Eio.Net.E (Connection_reset _), _) -> true

(* One connection: [talk send read] with [send] writing to it, and every
   read [In_memory.at_once]. *)
let on_connection env connect talk =
  Eio.Switch.run @@ fun sw ->
  let flow = connect ~sw in
  let r =
    Eio.Buf_read.of_flow ~max_size:1_000_000
      (In_memory.at_once ~clock:(Eio.Stdenv.mono_clock env) flow)
  in
  talk (fun s -> Eio.Flow.copy_string s flow) r

let with_server ?max_body ?max_header_bytes ?discard_limit ?body_budget routes f
    =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let connect =
    serve ~sw env ?max_body ?max_header_bytes ?discard_limit ?body_budget
      (Spindle.Test.app routes)
  in
  f (on_connection env connect)

let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let post path body =
  Printf.sprintf "POST %s HTTP/1.1\r\nHost: t\r\nContent-Length: %d\r\n\r\n%s"
    path (String.length body) body

let get ?(close = false) path =
  Printf.sprintf "GET %s HTTP/1.1\r\nHost: t\r\n%s\r\n" path
    (if close then "Connection: close\r\n" else "")

let smuggled = get "/hello/smuggled"

(* ------------------------------------------------------------------ *)
(* Bodies *)

(* A body nobody read is still the body: never the next request. *)
let test_an_unread_body_is_not_a_request () =
  with_server [ hello; ignores_its_body ] @@ fun connect ->
  connect @@ fun send r ->
  send (post "/ignore" smuggled ^ get "/hello/after");
  let first = read_answer r and second = read_answer r in
  check_string "the first is the route's" "ignored" first.body;
  check_string "the second is the next request's, not the body's" "after"
    second.body

let test_pipelined_requests_are_answered_in_order () =
  with_server [ hello; echo ] @@ fun connect ->
  connect @@ fun send r ->
  send (get "/hello/a" ^ post "/echo" "b" ^ get ~close:true "/hello/c");
  let bodies = List.init 3 (fun _ -> (read_answer r).body) in
  Alcotest.(check (list string)) "in order" [ "a"; "b"; "c" ] bodies;
  check_bool "and closed when asked" true (closed r)

let test_a_413_is_followed_by_the_next_request () =
  with_server ~max_body:16 [ hello; echo ] @@ fun connect ->
  connect @@ fun send r ->
  send (post "/echo" (String.make 64 'x' ^ smuggled) ^ get "/hello/after");
  check_int "too large" 413 (read_answer r).status;
  check_string "and the next request is itself" "after" (read_answer r).body

(* A route that did not want a body is not made to wait for a megabyte of
   one: nothing of it is read, and the connection goes. *)
let test_a_length_past_the_discard_limit_is_never_read () =
  with_server ~discard_limit:1024 [ ignores_its_body ] @@ fun connect ->
  connect @@ fun send r ->
  send "POST /ignore HTTP/1.1\r\nHost: t\r\nContent-Length: 1000000\r\n\r\n";
  let a = read_answer r in
  check_string "answered without the body" "ignored" a.body;
  Alcotest.(check (option string))
    "saying so" (Some "close") (header a "connection");
  check_bool "and closed" true (closed r)

(* A 304 is a head and nothing else: a body behind it would be read as the
   next answer. *)
(* A stream that says its length is framed by it, and a connection is
   carried past it only when the body said the truth. *)
let counted =
  let sent = Spindle.Path.str "sent" in
  Spindle.get
    Spindle.Path.(s "counted" / sent)
    Spindle.Returns.response
    (let+ sent = Spindle.param sent in
     Ok
       (Spindle.Response.stream ~length:5 (fun send ->
            let ( let* ) = Result.bind in
            let* () = send (String.sub sent 0 (min 2 (String.length sent))) in
            if String.length sent > 2 then
              send (String.sub sent 2 (String.length sent - 2))
            else Ok ())))

let test_a_stream_of_a_length_is_framed_by_it () =
  with_server [ counted; hello ] @@ fun connect ->
  connect (fun send r ->
      send (get "/counted/hello" ^ get "/hello/after");
      let first = read_answer r in
      check_string "framed by its length" "hello" first.body;
      Alcotest.(check (option string))
        "and not chunked" None
        (header first "transfer-encoding");
      check_string "the connection carries the next request" "after"
        (read_answer r).body);
  connect (fun send r ->
      send (get "/counted/hi" ^ get "/hello/after");
      let answer = Eio.Buf_read.take_all r in
      check_bool "one that sent less is cut off where it stopped" true
        (String.ends_with ~suffix:"\r\n\r\nhi" answer));
  connect (fun send r ->
      send (get "/counted/overlong" ^ get "/hello/after");
      let answer = Eio.Buf_read.take_all r in
      check_bool "one that sent more is cut at its length, and closed" true
        (String.ends_with ~suffix:"\r\n\r\noverl" answer))

(* A stream compressed as it goes: each chunk, fed to a gzip decoder as it
   arrives, is the event it carried -- nothing is held back for a later one. *)
let streamed_events =
  Spindle.get
    Spindle.Path.(s "ticks")
    Spindle.Returns.response
    (Spindle.Dep.return
       (Ok
          (Spindle.Response.events (fun send ->
               let ( let* ) = Result.bind in
               let* () = send "data: one\n\n" in
               let* () = send "data: two\n\n" in
               send "data: three\n\n"))))

let read_chunks r =
  let rec go acc =
    match int_of_string ("0x" ^ Eio.Buf_read.line r) with
    | 0 ->
        ignore (Eio.Buf_read.line r : string);
        List.rev acc
    | n ->
        let c = Eio.Buf_read.take n r in
        ignore (Eio.Buf_read.line r : string);
        go (c :: acc)
  in
  go []

let test_a_compressed_stream_arrives_as_it_is_sent () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let connect =
    serve ~sw env
      (Spindle.Test.app ~compress:Spindle.Compress.default [ streamed_events ])
  in
  on_connection env connect (fun send r ->
      send
        "GET /ticks HTTP/1.1\r\n\
         Host: t\r\n\
         Accept-Encoding: gzip\r\n\
         Connection: close\r\n\
         \r\n";
      let rec head () =
        match Eio.Buf_read.line r with "" -> () | _ -> head ()
      in
      head ();
      let chunks = read_chunks r in
      let decoded = Test_gz.gunzip_pieces chunks in
      Alcotest.(check (list string))
        "each event readable when its chunk arrives"
        [
          "data: one\n\n";
          "data: one\n\ndata: two\n\n";
          "data: one\n\ndata: two\n\ndata: three\n\n";
          "data: one\n\ndata: two\n\ndata: three\n\n";
        ]
        decoded)

let test_a_304_is_a_head_alone () =
  (* A site is read whole as it loads, so the files are read on the real
     backend and served from memory on the virtual one. *)
  let site =
    Eio_main.run @@ fun env ->
    let root =
      Eio.Path.(Eio.Stdenv.fs env / Filename.temp_dir "spindle_wire" "")
    in
    Eio.Path.save ~create:(`Or_truncate 0o644)
      Eio.Path.(root / "index.html")
      "FRONT DOOR";
    match Spindle.Static.load root with
    | Ok site -> site
    | Error m -> Alcotest.fail m
  in
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let connect =
    serve ~sw env (Spindle.Test.app [ Spindle.Static.route site ])
  in
  on_connection env connect @@ fun send r ->
  send (get "/");
  let tag = Option.value (header (read_answer r) "etag") ~default:"" in
  send
    (Printf.sprintf "GET / HTTP/1.1\r\nHost: t\r\nIf-None-Match: %s\r\n\r\n" tag
    ^ get ~close:true "/");
  let unchanged = read_answer r in
  check_int "not modified" 304 unchanged.status;
  Alcotest.(check (option string))
    "unframed" None
    (header unchanged "transfer-encoding");
  let next = read_answer r in
  check_int "the next answer is whole" 200 next.status;
  check_string "and its own" "FRONT DOOR" next.body

let chunked path body =
  Printf.sprintf
    "POST %s HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n%s" path
    body

let test_a_chunked_body_is_read_whole () =
  with_server [ hello; echo ] @@ fun connect ->
  connect @@ fun send r ->
  send
    (chunked "/echo"
       "5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nx-trailer: 1\r\n\r\n"
    ^ get "/hello/after");
  check_string "extensions and a trailer" "hello world" (read_answer r).body;
  check_string "and the connection carries on" "after" (read_answer r).body

(* Two ways a lenient reader takes a broken body for a finished one. *)
let test_a_malformed_chunk_ends_the_connection () =
  List.iter
    (fun (name, body) ->
      with_server [ hello; echo; ignores_its_body ] @@ fun connect ->
      connect (fun send r ->
          send (chunked "/echo" body ^ smuggled);
          check_int (name ^ ": refused") 400 (read_answer r).status;
          check_bool (name ^ ": and closed") true (closed r));
      connect (fun send r ->
          send (chunked "/ignore" body ^ smuggled);
          ignore (read_answer r : answer);
          check_bool
            (name ^ ", unread: closed, the rest never answered")
            true (closed r)))
    [
      ("a size that is not hex", "zz\r\nhello\r\n0\r\n\r\n");
      ("data not followed by CRLF", "5\r\nhelloXX\r\n0\r\n\r\n");
      ("a body that stops", "5\r\nhel");
    ]

(* RFC 9112 6.3: each of these could be framed two ways by two readers, and
   a proxy and a server that disagree are how one request becomes two. *)
let test_forbidden_framing_is_refused_and_closed () =
  List.iter
    (fun (name, headers, expected) ->
      with_server [ hello; echo ] @@ fun connect ->
      connect @@ fun send r ->
      send
        (Printf.sprintf "POST /echo HTTP/1.1\r\nHost: t\r\n%s\r\n0\r\n\r\n"
           headers
        ^ smuggled);
      check_int name expected (read_answer r).status;
      check_bool (name ^ ": closed") true (closed r))
    [
      ( "both framings",
        "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n",
        400 );
      ("two lengths", "Content-Length: 5\r\nContent-Length: 6\r\n", 400);
      ("a list of two lengths", "Content-Length: 5, 6\r\n", 400);
      ("a length that is not one", "Content-Length: -5\r\n", 400);
      ("not chunked last", "Transfer-Encoding: gzip\r\n", 400);
      ("a coding under chunked", "Transfer-Encoding: gzip, chunked\r\n", 501);
    ]

(* A head RFC 9112 forbids is refused and closed, never repaired: two
   readers that repair it differently -- this server and a proxy in front
   of it -- disagree about where the request ends. *)
let test_a_forbidden_head_is_refused_and_closed () =
  List.iter
    (fun (name, head, expected) ->
      with_server [ hello ] @@ fun connect ->
      connect @@ fun send r ->
      send head;
      check_int name expected (read_answer r).status;
      check_bool (name ^ ": closed") true (closed r))
    [
      ( "a folded line",
        "GET /hello/a HTTP/1.1\r\nHost: t\r\nX-A: 1\r\n 2\r\n\r\n",
        400 );
      ( "a space before the colon",
        "GET /hello/a HTTP/1.1\r\nHost : t\r\n\r\n",
        400 );
      ( "a name that is not a token",
        "GET /hello/a HTTP/1.1\r\nX(A): 1\r\n\r\n",
        400 );
      ("a bare CR", "GET /hello/a HTTP/1.1\r\nX-A: a\rb\r\n\r\n", 400);
      ( "a control character",
        "GET /hello/a HTTP/1.1\r\nX-A: a\001b\r\n\r\n",
        400 );
      ("a method that is not a token", "GE(T /hello/a HTTP/1.1\r\n\r\n", 400);
      ("two words", "GET /hello/a\r\n\r\n", 400);
      ("two spaces", "GET  /hello/a HTTP/1.1\r\n\r\n", 400);
      ("another version", "GET /hello/a HTTP/2.0\r\nHost: t\r\n\r\n", 505);
    ]

(* What RFC 9112 lets a server accept, it accepts: a line ended by a bare
   LF, and an empty line before the request line. *)
let test_a_lenient_head_is_read () =
  with_server [ hello ] @@ fun connect ->
  connect (fun send r ->
      send "GET /hello/lf HTTP/1.1\nHost: t\n\n";
      check_string "a bare LF" "lf" (read_answer r).body;
      send "\r\nGET /hello/after HTTP/1.1\r\nHost: t\r\n\r\n";
      check_string "after an empty line" "after" (read_answer r).body)

(* A client that asks first is told to go ahead only by a route that wants
   the body; one that does not is answered and the connection closed, since
   the client may never send what it asked about. *)
let test_a_body_asked_about_is_asked_for () =
  with_server [ echo; ignores_its_body ] @@ fun connect ->
  connect (fun send r ->
      send
        "POST /echo HTTP/1.1\r\n\
         Host: t\r\n\
         Content-Length: 5\r\n\
         Expect: 100-continue\r\n\
         \r\n";
      check_int "told to go ahead" 100 (read_answer r).status;
      send "hello";
      check_string "and read" "hello" (read_answer r).body);
  connect (fun send r ->
      send
        "POST /ignore HTTP/1.1\r\n\
         Host: t\r\n\
         Content-Length: 5\r\n\
         Expect: 100-continue\r\n\
         \r\n";
      check_string "answered without it" "ignored" (read_answer r).body;
      check_bool "and closed" true (closed r))

(* A length is a claim until its bytes come: a body that declares most of
   the budget and has sent a little of it holds only the little, so another
   fits beside it. The first is being read before the second arrives: its
   100 says the server has its head, length and all, and is reading its
   body. *)
let test_a_declared_length_holds_only_what_arrived () =
  let first_read, reading = Eio.Promise.create () in
  let second_answered, answered = Eio.Promise.create () in
  with_server ~body_budget:100 [ echo ] @@ fun connect ->
  Eio.Fiber.both
    (fun () ->
      connect (fun send r ->
          send
            "POST /echo HTTP/1.1\r\n\
             Host: t\r\n\
             Content-Length: 90\r\n\
             Expect: 100-continue\r\n\
             \r\n";
          check_int "told to go ahead" 100 (read_answer r).status;
          send (String.make 10 'a');
          Eio.Promise.resolve reading ();
          Eio.Promise.await second_answered;
          send (String.make 80 'a');
          check_int "and the first, once it has arrived" 200
            (read_answer r).status))
    (fun () ->
      Eio.Promise.await first_read;
      connect (fun send r ->
          send (post "/echo" (String.make 50 'b'));
          check_int "the second fits beside what has arrived" 200
            (read_answer r).status;
          Eio.Promise.resolve answered ()))

(* The budget bounds what the server holds at once, not per request: while
   one body is held, a second that would not fit beside it is refused. *)
let test_bodies_share_a_budget () =
  let release, released = Eio.Promise.create () in
  let holding, held = Eio.Promise.create () in
  let hold =
    Spindle.post
      Spindle.Path.(s "hold")
      Spindle.Returns.response
      (Spindle.Dep.map
         (fun b ->
           Eio.Promise.resolve held ();
           Eio.Promise.await release;
           Ok (Spindle.Response.make b))
         Spindle.body)
  in
  with_server ~body_budget:100 [ hold; echo ] @@ fun connect ->
  Eio.Fiber.both
    (fun () ->
      connect (fun send r ->
          send (post "/hold" (String.make 80 'a'));
          check_int "the first is held and answered" 200 (read_answer r).status))
    (fun () ->
      Eio.Promise.await holding;
      connect (fun send r ->
          send (post "/echo" (String.make 80 'b'));
          let a = read_answer r in
          check_int "the second does not fit" 503 a.status;
          Alcotest.(check (option string))
            "and says when to come back" (Some "1") (header a "retry-after");
          check_bool "closed" true (closed r));
      connect (fun send r ->
          send
            "POST /echo HTTP/1.1\r\n\
             Host: t\r\n\
             Content-Length: 80\r\n\
             Expect: 100-continue\r\n\
             \r\n";
          check_int "one that asks first is refused, not told to send" 503
            (read_answer r).status;
          check_bool "and closed" true (closed r));
      connect (fun send r ->
          send (post "/echo" (String.make 10 'c'));
          check_int "a small one still does" 200 (read_answer r).status);
      Eio.Promise.resolve released ())

(* A route that refuses without its body -- a missing session -- answers
   before a byte of a megabyte body has arrived, and the connection goes
   rather than wait for it. *)
let test_a_refusal_before_the_body_costs_nothing () =
  let guarded =
    Spindle.post
      Spindle.Path.(s "guarded")
      Spindle.Returns.response
      (let+ _ = Spindle.body
       and+ _ =
         Spindle.Dep.of_request
           ~needs:[ Spindle.Dep.Custom { name = "session"; doc = "a cookie" } ]
           ~refuses:[ code "signed_out" `Unauthorized ]
           (fun _ ->
             Error
               (Spindle.Refusal.make
                  (code "signed_out" `Unauthorized)
                  "Please sign in."))
       in
       Ok (Spindle.Response.empty ()))
  in
  with_server [ guarded ] @@ fun connect ->
  connect @@ fun send r ->
  send "POST /guarded HTTP/1.1\r\nHost: t\r\nContent-Length: 1048576\r\n\r\n";
  check_int "refused at once" 401 (read_answer r).status;
  check_bool "and closed" true (closed r)

(* ------------------------------------------------------------------ *)
(* Heads and time *)

let test_a_head_past_the_limit_is_431 () =
  with_server ~max_header_bytes:1024 [ hello ] @@ fun connect ->
  connect @@ fun send r ->
  send
    (Printf.sprintf "GET /hello/a HTTP/1.1\r\nHost: t\r\nX-Big: %s\r\n\r\n"
       (String.make 2000 'x'));
  check_int "too large" 431 (read_answer r).status;
  check_bool "and closed" true (closed r)

(* A head refused with a body still arriving behind it: the answer reaches
   the client before the connection goes, because the server closes its
   side first and drops what is still coming, rather than closing on
   unread bytes, which the kernel answers with a reset that can overtake
   the answer. *)
let test_a_refused_head_is_answered_before_the_connection_goes () =
  with_server [ hello; echo ] @@ fun connect ->
  connect @@ fun send r ->
  send
    ("POST /echo HTTP/1.1\r\n\
      Host: t\r\n\
      Content-Length: 5\r\n\
      Content-Length: 6\r\n\
      \r\n" ^ String.make 65_536 'x');
  check_int "refused" 400 (read_answer r).status;
  check_bool "and closed" true (closed r)

(* One domain's server, and [after s], which waits until [s] seconds of
   virtual time have gone: a limit passes when the test says so, and never
   because a machine was slow. *)
let with_mock_clock routes f =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let connect = serve ~sw env ~domains:1 (Spindle.Test.app routes) in
  let after s =
    Eio.Time.Mono.sleep_until
      (Eio.Stdenv.mono_clock env)
      (Mtime.of_uint64_ns (Int64.of_float (s *. 1e9)))
  in
  f (on_connection env connect) after

(* The sweep looks once a tick, a tenth of the shortest limit: a head still
   arriving a moment before its limit is read, and one that is not is
   refused within a tick of it. *)
let test_a_limit_passes_within_a_tick () =
  with_mock_clock [ hello ] @@ fun connect after ->
  connect @@ fun send r ->
  send "GET /hello/a HTTP/1.1\r\n";
  after 9.95;
  send "Host: t\r\n\r\n";
  check_string "a head finished a moment before its limit is answered" "a"
    (read_answer r).body;
  send "GET /hello/b HTTP/1.1\r\n";
  after 20.95;
  check_int "one that is not is 408 within a tick" 408 (read_answer r).status;
  check_bool "and closed" true (closed r)

let test_a_slow_head_is_408 () =
  with_mock_clock [ hello ] @@ fun connect after ->
  connect @@ fun send r ->
  send "GET /hello/a HTTP/1.1\r\n";
  after 11.;
  check_int "too slow" 408 (read_answer r).status;
  check_bool "and closed" true (closed r)

type quiet

let said : (string, quiet) Spindle.Event.kind = Spindle.Event.text "said"

(* A stream's chunks one at a time, as a browser reads them: it never ends. *)
let read_events_head r =
  let rec head () = match Eio.Buf_read.line r with "" -> () | _ -> head () in
  head ()

let read_chunk r =
  let n = int_of_string ("0x" ^ Eio.Buf_read.line r) in
  let s = Eio.Buf_read.take n r in
  ignore (Eio.Buf_read.line r : string);
  s

(* A stream that has sent nothing for fifteen seconds sends a comment, so
   nothing in between closes it as idle, and an event puts the next one
   off: the silence is counted from whatever went last. *)
let test_a_quiet_stream_is_kept_alive () =
  let again, say_again = Eio.Promise.create () in
  let third, say_third = Eio.Promise.create () in
  let quiet =
    Spindle.get
      Spindle.Path.(s "quiet")
      (Spindle.Returns.events Spindle.Event.[ declare said ])
      (Spindle.Dep.return
         (Ok
            (fun send ->
              let ( let* ) = Result.bind in
              let say s = send (Spindle.Event.make said s) in
              let* () = say "hello" in
              Eio.Promise.await again;
              let* () = say "again" in
              Eio.Promise.await third;
              let* () = say "third" in
              Eio.Fiber.await_cancel ())))
  in
  with_mock_clock [ quiet ] @@ fun connect after ->
  connect @@ fun send r ->
  send (get "/quiet");
  read_events_head r;
  check_string "the event" "event: said\ndata: hello\n\n" (read_chunk r);
  after 15.;
  check_string "then, fifteen seconds on, a comment" ": keep-alive\n\n"
    (read_chunk r);
  after 20.;
  Eio.Promise.resolve say_again ();
  check_string "an event" "event: said\ndata: again\n\n" (read_chunk r);
  after 34.9;
  Eio.Promise.resolve say_third ();
  check_string "nothing due fifteen seconds after the comment"
    "event: said\ndata: third\n\n" (read_chunk r);
  after 50.;
  check_string "only fifteen after the last event" ": keep-alive\n\n"
    (read_chunk r)

let test_an_idle_connection_is_closed () =
  with_mock_clock [ hello ] @@ fun connect after ->
  connect @@ fun send r ->
  send (get "/hello/a");
  check_string "answered" "a" (read_answer r).body;
  after 61.;
  check_bool "then closed once idle" true (closed r)

(* A byte a second is inside every idle wait, but the body has twenty
   seconds, and 500 bytes a second after them. *)
let test_a_body_that_falls_behind_is_cut_off () =
  with_mock_clock [ echo ] @@ fun connect after ->
  connect @@ fun send r ->
  send "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 1000\r\n\r\n";
  for second = 1 to 20 do
    after (float_of_int second);
    send "x"
  done;
  after 21.;
  let a = read_answer r in
  check_int "unreadable" 400 a.status;
  check_bool "said as such" true
    (String.starts_with ~prefix:{|{"error":"unreadable"|} a.body);
  check_bool "and closed" true (closed r)

let test_a_body_kept_at_the_rate_is_read_whole () =
  with_mock_clock [ echo ] @@ fun connect after ->
  connect @@ fun send r ->
  let part = String.make 500 'x' in
  send "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 2000\r\n\r\n";
  (* Each 500 bytes is a second more: the thousand sent behind the head carry
     the body to twenty-two seconds, and the part sent at nineteen to
     twenty-three -- which only its being read can pay for. *)
  send (part ^ part);
  after 19.;
  send part;
  after 21.;
  after 22.5;
  send part;
  let a = read_answer r in
  check_int "read" 200 a.status;
  check_int "whole" 2000 (String.length a.body)

(* ------------------------------------------------------------------ *)
(* Responses *)

let ran = Atomic.make false

let kinds =
  [
    ( "/buffered",
      Spindle.get
        Spindle.Path.(s "buffered")
        Spindle.Returns.response
        (Spindle.Dep.return (Ok (Spindle.Response.make "body"))) );
    ( "/stream",
      Spindle.get
        Spindle.Path.(s "stream")
        Spindle.Returns.response
        (Spindle.Dep.return
           (Ok
              (Spindle.Response.stream (fun send ->
                   Atomic.set ran true;
                   send "a")))) );
    ( "/events",
      Spindle.get
        Spindle.Path.(s "events")
        Spindle.Returns.response
        (Spindle.Dep.return
           (Ok
              (Spindle.Response.events (fun send ->
                   Atomic.set ran true;
                   send "data: 1\n\n")))) );
    ( "/away",
      Spindle.get
        Spindle.Path.(s "away")
        Spindle.Returns.response
        (Spindle.Dep.return (Ok (Spindle.Response.redirect "/there"))) );
    ( "/nothing",
      Spindle.get
        Spindle.Path.(s "nothing")
        Spindle.Returns.response
        (Spindle.Dep.return (Ok (Spindle.Response.empty ()))) );
    ( "/refused",
      Spindle.get
        ~refuses:[ code "conflict" `Conflict ]
        Spindle.Path.(s "refused")
        Spindle.Returns.response
        (Spindle.Dep.return
           (Error (Spindle.Refusal.make (code "conflict" `Conflict) "No."))) );
  ]

(* What differs between two answers to one request and nothing else. *)
let comparable headers =
  List.filter
    (fun (k, _) -> not (List.mem k [ "connection"; "x-request-id" ]))
    headers
  |> List.map (fun (k, v) -> (String.lowercase_ascii k, v))
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* One render, so an in-process test sees the head the wire gets; and HEAD
   is that head with nothing after it -- a stream's producer never runs. *)
let test_head_is_the_head_on_every_kind () =
  with_server (List.map snd kinds) @@ fun connect ->
  let served = Spindle.Test.app (List.map snd kinds) in
  List.iter
    (fun (path, _) ->
      Atomic.set ran false;
      connect (fun send r ->
          send
            (Printf.sprintf "HEAD %s HTTP/1.1\r\nHost: t\r\n\r\n" path
            ^ get "/buffered");
          let a = read_answer ~head:true r in
          let t =
            Spindle.Test.call ~headers:[ ("host", "t") ] served `HEAD path
          in
          check_int (path ^ ": the status") t.status a.status;
          Alcotest.(check (list (pair string string)))
            (path ^ ": the headers Test.call sees")
            (comparable t.headers) (comparable a.headers);
          check_string (path ^ ": no body in-process") "" t.body;
          check_bool (path ^ ": no producer run") false (Atomic.get ran);
          check_string
            (path ^ ": nothing after the head")
            "body" (read_answer r).body))
    kinds

let test_a_204_says_no_length () =
  with_server (List.map snd kinds) @@ fun connect ->
  connect @@ fun send r ->
  let a =
    send (get "/nothing");
    read_answer r
  in
  check_int "no content" 204 a.status;
  Alcotest.(check (option string))
    "and no length" None
    (header a "content-length")

let test_a_header_that_could_split_the_response_is_never_written () =
  let split =
    Spindle.get
      Spindle.Path.(s "split")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.make
               ~headers:[ ("x-note", "a\r\nx-evil: 1") ]
               "x")))
  in
  let t = Spindle.Test.call (Spindle.Test.app [ split ]) `GET "/split" in
  check_int "in-process, ours to fix" 500 t.status;
  with_server [ split ] @@ fun connect ->
  connect @@ fun send r ->
  send (get "/split");
  let a = read_answer r in
  check_int "on the wire, the same" 500 a.status;
  Alcotest.(check (option string))
    "and no header of theirs" None (header a "x-evil")

let test_http_1_0_is_closed_after_its_answer () =
  with_server [ hello ] @@ fun connect ->
  connect @@ fun send r ->
  send "GET /hello/a HTTP/1.0\r\n\r\n";
  check_string "answered" "a" (read_answer r).body;
  check_bool "and closed" true (closed r)

(* ------------------------------------------------------------------ *)
(* Takeover *)

let echo_lines =
  Spindle.get
    Spindle.Path.(s "upgrade")
    Spindle.Returns.response
    (Spindle.Dep.return
       (Ok
          (Spindle.Response.takeover ~protocol:"echo"
             (fun { Spindle.Response.reader; writer; _ } ->
               let rec loop () =
                 match Eio.Buf_read.line reader with
                 | line ->
                     Eio.Buf_write.string writer (line ^ "\n");
                     Eio.Buf_write.flush writer;
                     loop ()
                 | exception End_of_file -> ()
               in
               loop ()))))

(* The connection is the route's after its head, and still the server's to
   end: a stop gives it the drain to say goodbye, as any answer in flight,
   and cancels it when the drain runs out. *)
let test_a_takeover_owns_the_connection_until_the_server_stops () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let stop, stopping = Eio.Promise.create () in
  let drain_s = 0.5 in
  let connect =
    serve ~sw env ~stop ~drain_s (Spindle.Test.app [ echo_lines ])
  in
  on_connection env connect @@ fun send r ->
  (* The first bytes of the new protocol arrive with the request. *)
  send
    "GET /upgrade HTTP/1.1\r\n\
     Host: t\r\n\
     Connection: upgrade\r\n\
     Upgrade: echo\r\n\
     \r\n\
     ping\n";
  check_int "switching" 101 (read_answer r).status;
  check_string "the bytes sent with the request" "ping" (Eio.Buf_read.line r);
  send "pong\n";
  check_string "and after it" "pong" (Eio.Buf_read.line r);
  Eio.Promise.resolve stopping ();
  Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) drain_s;
  check_bool "ended by the stop as its drain ran out" true (closed r)

(* ------------------------------------------------------------------ *)
(* A body read as it arrives *)

let test_a_streamed_body_is_past_max_body () =
  with_server ~max_body:1024 [ upload ] @@ fun connect ->
  connect @@ fun send r ->
  send (post "/upload" (String.make 300_000 'x'));
  check_string "every byte, past the server's limit" "300000"
    (read_answer r).body;
  send (chunked "/upload" "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
  check_string "a chunked one too" "11" (read_answer r).body

let test_a_streamed_body_past_its_own_limit_is_413 () =
  with_server [ upload; hello ] @@ fun connect ->
  connect @@ fun send r ->
  send "POST /upload HTTP/1.1\r\nHost: t\r\nContent-Length: 1000001\r\n\r\n";
  let a = read_answer r in
  check_int "a declared length, before any is read" 413 a.status;
  check_bool "and closed, with more left than is worth reading" true (closed r);
  with_server [ upload; hello ] @@ fun connect ->
  connect @@ fun send r ->
  let chunk = Printf.sprintf "%x\r\n%s\r\n" 65536 (String.make 65536 'x') in
  send
    (chunked "/upload"
       (String.concat "" (List.init 16 (fun _ -> chunk)) ^ "0\r\n\r\n"));
  check_int "a chunked one, once it passes" 413 (read_answer r).status

let test_what_a_stream_left_is_discarded () =
  with_server [ reads_a_part; hello ] @@ fun connect ->
  connect @@ fun send r ->
  send (post "/part" (String.make 60_000 'x' ^ smuggled) ^ get "/hello/after");
  check_string "the route read a part" "x" (read_answer r).body;
  check_string "and the next request is itself" "after" (read_answer r).body

(* A read waits only as long as the body's one allowance has left, so a
   byte sent just inside each read's wait still runs out: twenty seconds,
   spent across twenty reads of a byte each. *)
let test_a_streamed_body_that_falls_behind_is_cut_off () =
  with_mock_clock [ upload ] @@ fun connect after ->
  connect @@ fun send r ->
  send "POST /upload HTTP/1.1\r\nHost: t\r\nContent-Length: 1000\r\n\r\n";
  for second = 1 to 20 do
    after (float_of_int second);
    send "x"
  done;
  after 21.;
  let a = read_answer r in
  check_int "unreadable" 400 a.status;
  check_bool "and closed" true (closed r)

let () =
  Alcotest.run "wire"
    [
      ( "bodies",
        [
          Alcotest.test_case "an unread body is not a request" `Quick
            test_an_unread_body_is_not_a_request;
          Alcotest.test_case "pipelined requests are answered in order" `Quick
            test_pipelined_requests_are_answered_in_order;
          Alcotest.test_case "a 413 is followed by the next request" `Quick
            test_a_413_is_followed_by_the_next_request;
          Alcotest.test_case "a length past the discard limit is never read"
            `Quick test_a_length_past_the_discard_limit_is_never_read;
          Alcotest.test_case "a 304 is a head alone" `Quick
            test_a_304_is_a_head_alone;
          Alcotest.test_case "a stream of a length is framed by it" `Quick
            test_a_stream_of_a_length_is_framed_by_it;
          Alcotest.test_case "a compressed stream arrives as it is sent" `Quick
            test_a_compressed_stream_arrives_as_it_is_sent;
          Alcotest.test_case "a streamed body is past max_body" `Quick
            test_a_streamed_body_is_past_max_body;
          Alcotest.test_case "a streamed body past its own limit is 413" `Quick
            test_a_streamed_body_past_its_own_limit_is_413;
          Alcotest.test_case "what a stream left is discarded" `Quick
            test_what_a_stream_left_is_discarded;
          Alcotest.test_case "a streamed body that falls behind is cut off"
            `Quick test_a_streamed_body_that_falls_behind_is_cut_off;
          Alcotest.test_case "a chunked body is read whole" `Quick
            test_a_chunked_body_is_read_whole;
          Alcotest.test_case "a malformed chunk ends the connection" `Quick
            test_a_malformed_chunk_ends_the_connection;
          Alcotest.test_case "forbidden framing is refused and closed" `Quick
            test_forbidden_framing_is_refused_and_closed;
          Alcotest.test_case "a body asked about is asked for" `Quick
            test_a_body_asked_about_is_asked_for;
          Alcotest.test_case "a declared length holds only what arrived" `Quick
            test_a_declared_length_holds_only_what_arrived;
          Alcotest.test_case "bodies share a budget" `Quick
            test_bodies_share_a_budget;
          Alcotest.test_case "a refusal before the body costs nothing" `Quick
            test_a_refusal_before_the_body_costs_nothing;
        ] );
      ( "heads and time",
        [
          Alcotest.test_case "a forbidden head is refused and closed" `Quick
            test_a_forbidden_head_is_refused_and_closed;
          Alcotest.test_case
            "a refused head is answered before the connection goes" `Quick
            test_a_refused_head_is_answered_before_the_connection_goes;
          Alcotest.test_case "a lenient head is read" `Quick
            test_a_lenient_head_is_read;
          Alcotest.test_case "a head past the limit is 431" `Quick
            test_a_head_past_the_limit_is_431;
          Alcotest.test_case "a slow head is 408" `Quick test_a_slow_head_is_408;
          Alcotest.test_case "an idle connection is closed" `Quick
            test_an_idle_connection_is_closed;
          Alcotest.test_case "a quiet stream is kept alive" `Quick
            test_a_quiet_stream_is_kept_alive;
          Alcotest.test_case "a body that falls behind the rate is cut off"
            `Quick test_a_body_that_falls_behind_is_cut_off;
          Alcotest.test_case "a body kept at the rate is read whole" `Quick
            test_a_body_kept_at_the_rate_is_read_whole;
          Alcotest.test_case "a limit passes within a tick" `Quick
            test_a_limit_passes_within_a_tick;
        ] );
      ( "responses",
        [
          Alcotest.test_case "HEAD is the head, on every kind" `Quick
            test_head_is_the_head_on_every_kind;
          Alcotest.test_case "a 204 says no length" `Quick
            test_a_204_says_no_length;
          Alcotest.test_case "a header that could split is never written" `Quick
            test_a_header_that_could_split_the_response_is_never_written;
          Alcotest.test_case "HTTP/1.0 is closed after its answer" `Quick
            test_http_1_0_is_closed_after_its_answer;
        ] );
      ( "takeover",
        [
          Alcotest.test_case "owns the connection until the server stops" `Quick
            test_a_takeover_owns_the_connection_until_the_server_stops;
        ] );
    ]
