(* WebSockets as an application uses them: a protocol declared once, a
   route serving it, the client calling it, a test driving it, and what the
   framework does around them -- the close a handler's ending asks for, a
   refusal before the upgrade, keep-alive, a server stopping, and the
   document. What RFC 6455 requires of either end is test_websocket_rfc's. *)

module Ws = Spindle.Websocket
open Spindle.Syntax

let ( let* ) = Result.bind

type said = { text : string }

let said_json =
  Wiretype.Object.map ~kind:"said" (fun text -> { text })
  |> Wiretype.Object.mem "text" Wiretype.string ~enc:(fun s -> s.text)
  |> Wiretype.Object.finish

let chat = Ws.(protocol ~client:(json said_json) ~server:(json said_json) ())

let echo ws =
  let rec loop () =
    let* said = Ws.receive ws in
    let* () = Ws.send ws said in
    loop ()
  in
  loop ()

let forbidden =
  Spindle.Refusal.Code.make "forbidden" ~status:`Forbidden ~doc:"Not for you."

let routes =
  [
    Spindle.get
      Spindle.Path.(s "echo")
      (Spindle.Returns.websocket chat)
      (let+ () = Spindle.Dep.return () in
       Ok echo);
    Spindle.get ~refuses:[ forbidden ]
      Spindle.Path.(s "closed")
      (Spindle.Returns.websocket chat)
      (let+ () = Spindle.Dep.return () in
       Error (Spindle.Refusal.make forbidden "Not for you."));
    Spindle.get
      Spindle.Path.(s "raises")
      (Spindle.Returns.websocket chat)
      (let+ () = Spindle.Dep.return () in
       Ok (fun _ -> failwith "a bug"));
  ]

let app = Spindle.Test.app routes

let outcome = function
  | Ok v -> Ok v
  | Error (Spindle.Test.Refused r) ->
      Error (Printf.sprintf "refused %d" r.status)
  | Error (Spindle.Test.Ended e) -> Error (Ws.error_to_string e)

let check_outcome = Alcotest.(check (result string string))

(* ------------------------------------------------------------------ *)
(* In-process *)

let test_a_socket_is_typed_both_ways () =
  let got =
    Spindle.Test.websocket app chat "/echo" (fun ws ->
        let* () = Ws.send ws { text = "hello" } in
        let* back = Ws.receive ws in
        Ok back.text)
  in
  check_outcome "what went came back, typed" (Ok "hello") (outcome got)

(* A handler's loop ends at the first thing that went wrong, and how it
   ended is the close: a message its description cannot read is 1007. *)
let unreadable = Ws.protocol ~client:Ws.text ~server:(Ws.json said_json) ()

let test_a_message_it_cannot_read_closes_it_with_1007 () =
  let got =
    Spindle.Test.websocket app unreadable "/echo" (fun ws ->
        let* () = Ws.send ws {|{"nope":1}|} in
        let* back = Ws.receive ws in
        Ok back.text)
  in
  check_outcome "closed as the handler's ending said"
    (Error "closed, 1007: A message this socket could not read.") (outcome got)

let test_a_refusal_comes_before_the_upgrade () =
  check_outcome "refused as the route said" (Error "refused 403")
    (outcome (Spindle.Test.websocket app chat "/closed" (fun _ -> Ok "opened")))

let test_a_handler_that_raises_is_closed_with_1011 () =
  let got =
    Spindle.Test.websocket app chat "/raises" (fun ws ->
        let* back = Ws.receive ws in
        Ok back.text)
  in
  check_outcome "closed as our bug"
    (Error "closed, 1011: Something went wrong at our end.") (outcome got)

let test_another_sites_page_cannot_open_one () =
  let got =
    Spindle.Test.websocket
      ~headers:
        [
          ("origin", "https://elsewhere.example");
          ("sec-fetch-site", "cross-site");
        ]
      app chat "/echo"
      (fun _ -> Ok "opened")
  in
  check_outcome "refused, though it is a GET" (Error "refused 403")
    (outcome got)

let test_a_socket_route_is_a_get () =
  match
    Spindle.App.make
      [
        Spindle.post
          Spindle.Path.(s "echo")
          (Spindle.Returns.websocket chat)
          (let+ () = Spindle.Dep.return () in
           Ok echo);
      ]
  with
  | Ok _ -> Alcotest.fail "a POST socket was served"
  | Error m ->
      Alcotest.(check bool)
        "refused, saying why" true
        (String.length m > 0
        &&
        let rec has i =
          i + 3 <= String.length m
          && (String.equal (String.sub m i 3) "GET" || has (i + 1))
        in
        has 0)

(* ------------------------------------------------------------------ *)
(* Over sockets *)

let serve ~sw env ?stop routes =
  let socket =
    Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains:1
        ~now:(fun () -> 0)
        ?stop ~drain_s:0.1 [ socket ] (Spindle.Test.app routes);
      `Stop_daemon);
  port

let client ~sw env ?authenticator () =
  Spindle_client.create ~sw ~net:(Eio.Stdenv.net env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ?authenticator ()

let called = function
  | Ok v -> Ok v
  | Error e -> Error (Spindle_client.websocket_error_to_string e)

let test_the_client_calls_the_server env () =
  Eio.Switch.run @@ fun sw ->
  let port = serve ~sw env routes in
  let got =
    Spindle_client.websocket (client ~sw env ()) chat
      (Printf.sprintf "ws://127.0.0.1:%d/echo" port) (fun ws ->
        let* () = Ws.send ws { text = "hi" } in
        let* () = Ws.send ws { text = String.make 100_000 'x' } in
        let* a = Ws.receive ws in
        let* b = Ws.receive ws in
        Ok (a.text ^ " " ^ string_of_int (String.length b.text)))
  in
  check_outcome "the same protocol from the other end" (Ok "hi 100000")
    (called got)

(* A program's client, for as long as its function runs, taken from the
   environment as a server's routes are. *)
let test_a_client_runs_as_long_as_its_function env () =
  Eio.Switch.run @@ fun sw ->
  let port = serve ~sw env routes in
  let got =
    Spindle_client.run env @@ fun client ->
    Spindle_client.websocket client chat
      (Printf.sprintf "ws://127.0.0.1:%d/echo" port) (fun ws ->
        let* () = Ws.send ws { text = "from run" } in
        let* back = Ws.receive ws in
        Ok back.text)
  in
  check_outcome "a client made and gone" (Ok "from run") (called got)

(* A client's socket gets one line when it ends, as a server's does, and
   never its query, where a credential travels. *)
let test_a_client_socket_says_how_it_ended env () =
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Debug)
    ~out:(fun l -> lines := l :: !lines)
    ();
  Eio.Switch.run @@ fun sw ->
  let port = serve ~sw env routes in
  let c = client ~sw env () in
  ignore
    (Spindle_client.websocket c chat
       (Printf.sprintf "ws://127.0.0.1:%d/echo?token=hush" port) (fun ws ->
         let* () = Ws.send ws { text = "hi" } in
         let* _ = Ws.receive ws in
         Ok ())
      : (unit, Spindle_client.websocket_error) result);
  ignore
    (Spindle_client.websocket c chat
       (Printf.sprintf "ws://127.0.0.1:%d/closed" port) (fun _ -> Ok ())
      : (unit, Spindle_client.websocket_error) result);
  let has sub l =
    let n = String.length sub in
    let rec at i =
      i + n <= String.length l
      && (String.equal (String.sub l i n) sub || at (i + 1))
    in
    at 0
  in
  let said sub = List.exists (has sub) !lines in
  Alcotest.(check bool)
    "a clean close, at info" true
    (said
       {|"level":"info","logger.name":"spindle.client","message":"socket to 127.0.0.1/echo ended: closed"|});
  Alcotest.(check bool)
    "a refusal, at warn" true
    (said
       {|"level":"warn","logger.name":"spindle.client","message":"socket to 127.0.0.1/closed ended: answered 403|});
  Alcotest.(check bool) "and never the query" false (said "hush")

let test_a_refusal_reaches_the_client env () =
  Eio.Switch.run @@ fun sw ->
  let port = serve ~sw env routes in
  let got =
    Spindle_client.websocket (client ~sw env ()) chat
      (Printf.sprintf "ws://127.0.0.1:%d/closed" port) (fun _ -> Ok "opened")
  in
  check_outcome "refused, with its status"
    (Error "answered 403, which opens no socket") (called got)

(* A certificate of the test's own, and a front that speaks TLS to the
   client and plain HTTP to the server, as a proxy before one does. *)
let tls_front ~sw env ~port =
  Mirage_crypto_rng_unix.use_default ();
  let key = X509.Private_key.generate `P256 in
  let name =
    X509.Distinguished_name.
      [ Relative_distinguished_name.singleton (CN (Common_name.v "localhost")) ]
  in
  let extensions =
    X509.Extension.singleton Subject_alt_name
      (false, X509.General_name.singleton DNS [ "localhost" ])
  in
  let certificate =
    match X509.Signing_request.create name key with
    | Error (`Msg m) -> Alcotest.fail m
    | Ok csr -> (
        match
          X509.Signing_request.sign csr ~valid_from:Ptime.epoch
            ~valid_until:
              (Option.value (Ptime.of_float_s 4e9) ~default:Ptime.max)
            ~extensions key name
        with
        | Ok c -> c
        | Error e -> Alcotest.failf "%a" X509.Validation.pp_signature_error e)
  in
  let config =
    match
      Tls.Config.server ~certificates:(`Single ([ certificate ], key)) ()
    with
    | Ok c -> c
    | Error (`Msg m) -> Alcotest.fail m
  in
  let fingerprint =
    X509.Public_key.fingerprint ~hash:`SHA256 (X509.Private_key.public key)
  in
  let authenticator : X509.Authenticator.t =
   fun ?ip ~host chain ->
    X509.Validation.trust_key_fingerprint ?ip ~host
      ~time:(fun () -> Ptime.of_float_s (Unix.gettimeofday ()))
      ~hash:`SHA256 ~fingerprint chain
  in
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen net ~sw ~backlog:4 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let front =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec accept () =
        Eio.Net.accept_fork socket ~sw
          ~on_error:(fun _ -> ())
          (fun flow _ ->
            let tls = Tls_eio.server_of_flow config flow in
            Eio.Switch.run @@ fun sw ->
            let back =
              Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
            in
            Eio.Fiber.first
              (fun () -> Eio.Flow.copy tls back)
              (fun () -> Eio.Flow.copy back tls));
        accept ()
      in
      accept ());
  (front, authenticator)

let test_the_client_speaks_wss env () =
  Eio.Switch.run @@ fun sw ->
  let port = serve ~sw env routes in
  let front, authenticator = tls_front ~sw env ~port in
  let got =
    Spindle_client.websocket (client ~sw env ~authenticator ()) chat
      (Printf.sprintf "wss://localhost:%d/echo" front) (fun ws ->
        let* () = Ws.send ws { text = "secret" } in
        let* back = Ws.receive ws in
        Ok back.text)
  in
  check_outcome "over TLS" (Ok "secret") (called got)

(* Everybody in a room hears what anybody says, each message encoded once. *)
let test_a_room_is_a_broadcast_of_frames env () =
  let hub : (unit, said Ws.encoded) Spindle.Broadcast.t =
    Spindle.Broadcast.create ()
  in
  let joined = Atomic.make 0 and changed = Eio.Condition.create () in
  let until_joined n =
    Eio.Condition.loop_no_mutex changed (fun () ->
        if Atomic.get joined >= n then Some () else None)
  in
  let room =
    Spindle.get
      Spindle.Path.(s "room")
      (Spindle.Returns.websocket chat)
      (let+ () = Spindle.Dep.return () in
       Ok
         (fun ws ->
           let sub = Spindle.Broadcast.subscribe hub ~topic:"room" () in
           Atomic.incr joined;
           Eio.Condition.broadcast changed;
           Fun.protect
             ~finally:(fun () -> Spindle.Broadcast.unsubscribe hub sub)
             (fun () ->
               Eio.Fiber.first
                 (fun () ->
                   let rec hear () =
                     let* said = Ws.receive ws in
                     Spindle.Broadcast.publish hub ~topic:"room"
                       (Ws.encode (Ws.server chat) said);
                     hear ()
                   in
                   hear ())
                 (fun () ->
                   let rec tell () =
                     match Spindle.Broadcast.next sub with
                     | Some f ->
                         let* () = Ws.send_encoded ws f in
                         tell ()
                     | None -> Ok ()
                   in
                   tell ()))))
  in
  Eio.Switch.run @@ fun sw ->
  let port = serve ~sw env [ room ] in
  let c = client ~sw env () in
  let url = Printf.sprintf "ws://127.0.0.1:%d/room" port in
  let listener_heard = ref "" in
  Eio.Fiber.both
    (fun () ->
      ignore
        (Spindle_client.websocket c chat url (fun ws ->
             let* said = Ws.receive ws in
             listener_heard := said.text;
             Ok ())
          : (unit, Spindle_client.websocket_error) result))
    (fun () ->
      until_joined 1;
      ignore
        (Spindle_client.websocket c chat url (fun ws ->
             until_joined 2;
             let* () = Ws.send ws { text = "to everybody" } in
             let* back = Ws.receive ws in
             Ok back.text)
          : (string, Spindle_client.websocket_error) result));
  Alcotest.(check string)
    "the other one heard it" "to everybody" !listener_heard

(* A socket quiet for fifteen seconds is pinged, and one still silent at
   thirty is gone: on virtual time, each read at the instant the test says,
   so a ping or an end that came late reads as late. *)
let test_a_silent_peer_is_pinged_then_dropped () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.mono_clock env in
  let listening, connect = In_memory.listen () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on ~mono_clock:clock
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains:1
        ~now:(fun () -> 0)
        [ listening ] (Spindle.Test.app routes);
      `Stop_daemon);
  let flow = connect ~sw in
  let r = Eio.Buf_read.of_flow flow ~max_size:65536 in
  Eio.Flow.copy_string
    "GET /echo HTTP/1.1\r\n\
     Host: t\r\n\
     Upgrade: websocket\r\n\
     Connection: Upgrade\r\n\
     Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
     Sec-WebSocket-Version: 13\r\n\
     \r\n"
    flow;
  let rec head () = match Eio.Buf_read.line r with "" -> () | _ -> head () in
  head ();
  let at s read =
    let instant = Mtime.of_uint64_ns (Int64.of_float (s *. 1e9)) in
    Eio.Time.Mono.sleep_until clock instant;
    let v = read () in
    Alcotest.(check bool)
      "read as the instant came" true
      (Mtime.equal instant (Eio.Time.Mono.now clock));
    v
  in
  let ping = at 15. (fun () -> Eio.Buf_read.take 2 r) in
  Alcotest.(check int) "fifteen seconds on, a ping" 0x89 (Char.code ping.[0]);
  let gone =
    at 31. (fun () ->
        match Eio.Buf_read.take 1 r with
        | _ -> false
        | exception End_of_file -> true)
  in
  Alcotest.(check bool) "thirty, and the connection is ended" true gone

let test_a_stopping_server_says_going_away env () =
  Eio.Switch.run @@ fun sw ->
  let stop, stopping = Eio.Promise.create () in
  let port = serve ~sw env ~stop routes in
  let got =
    Spindle_client.websocket (client ~sw env ()) chat
      (Printf.sprintf "ws://127.0.0.1:%d/echo" port) (fun ws ->
        Eio.Promise.resolve stopping ();
        let* back = Ws.receive ws in
        Ok back.text)
  in
  check_outcome "told why" (Error "closed, 1001: The server is stopping.")
    (called got)

(* ------------------------------------------------------------------ *)
(* Described *)

let test_a_socket_is_in_the_document () =
  let doc =
    match Spindle.Openapi.document ~title:"T" ~version:"1" app with
    | Ok d -> Yojson.Safe.from_string d
    | Error e -> Alcotest.failf "no document: %s" (String.concat "; " e)
  in
  let member path j =
    List.fold_left (fun j k -> Yojson.Safe.Util.member k j) j path
  in
  let answer = member [ "paths"; "/echo"; "get"; "responses"; "101" ] doc in
  Alcotest.(check bool)
    "a 101, described" true
    (not (Yojson.Safe.equal (member [ "description" ] answer) `Null));
  Alcotest.(check bool)
    "what the client sends" true
    (not (Yojson.Safe.equal (member [ "x-websocket"; "client" ] answer) `Null));
  Alcotest.(check bool)
    "and what the server does" true
    (not (Yojson.Safe.equal (member [ "x-websocket"; "server" ] answer) `Null));
  let codes =
    Yojson.Safe.Util.keys (member [ "paths"; "/echo"; "get"; "responses" ] doc)
  in
  Alcotest.(check bool)
    "the refusals a socket may answer" true
    (List.for_all (fun c -> List.mem c codes) [ "400"; "403"; "426" ])

let test_a_socket_is_in_the_zod_module () =
  let m =
    match Spindle.Zod.module_ app with
    | Ok m -> m
    | Error e -> Alcotest.failf "no module: %s" (String.concat "; " e)
  in
  let has sub =
    let n = String.length sub in
    let rec at i =
      i + n <= String.length m
      && (String.equal (String.sub m i n) sub || at (i + 1))
    in
    at 0
  in
  Alcotest.(check bool) "each side's schema" true (has "websocket: { client: ")

let () =
  Eio_main.run @@ fun env ->
  Alcotest.run "websocket"
    [
      ( "in-process",
        [
          Alcotest.test_case "a socket is typed both ways" `Quick
            test_a_socket_is_typed_both_ways;
          Alcotest.test_case "a message it cannot read closes it with 1007"
            `Quick test_a_message_it_cannot_read_closes_it_with_1007;
          Alcotest.test_case "a refusal comes before the upgrade" `Quick
            test_a_refusal_comes_before_the_upgrade;
          Alcotest.test_case "a handler that raises is closed with 1011" `Quick
            test_a_handler_that_raises_is_closed_with_1011;
          Alcotest.test_case "another site's page cannot open one" `Quick
            test_another_sites_page_cannot_open_one;
          Alcotest.test_case "a socket route is a GET" `Quick
            test_a_socket_route_is_a_get;
        ] );
      ( "over sockets",
        [
          Alcotest.test_case "the client calls the server" `Quick
            (test_the_client_calls_the_server env);
          Alcotest.test_case "a client runs as long as its function" `Quick
            (test_a_client_runs_as_long_as_its_function env);
          Alcotest.test_case "a refusal reaches the client" `Quick
            (test_a_refusal_reaches_the_client env);
          Alcotest.test_case "a client socket says how it ended" `Quick
            (test_a_client_socket_says_how_it_ended env);
          Alcotest.test_case "the client speaks wss" `Quick
            (test_the_client_speaks_wss env);
          Alcotest.test_case "a room is a broadcast of frames" `Quick
            (test_a_room_is_a_broadcast_of_frames env);
          Alcotest.test_case "a silent peer is pinged, then dropped" `Quick
            test_a_silent_peer_is_pinged_then_dropped;
          Alcotest.test_case "a stopping server says going away" `Quick
            (test_a_stopping_server_says_going_away env);
        ] );
      ( "described",
        [
          Alcotest.test_case "a socket is in the document" `Quick
            test_a_socket_is_in_the_document;
          Alcotest.test_case "a socket is in the zod module" `Quick
            test_a_socket_is_in_the_zod_module;
        ] );
    ]
