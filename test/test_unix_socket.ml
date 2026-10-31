(* HTTP over a Unix socket: the client reaching one named in its URL, the
   server opening one only its owner can connect to, and MCP over it whole.
   Every case runs against real sockets, in a directory the case makes. *)

module Mcp = Spindle_mcp
module Client = Spindle_mcp_client

let check_int = Alcotest.(check int)
let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let contains ~sub s =
  let n = String.length sub in
  let rec at i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || at (i + 1))
  in
  at 0

(* A directory only this user may enter, as a server's socket needs. *)
let private_dir () = Filename.temp_dir ~perms:0o700 "spindle" ""

let url_of path target =
  "http+unix://" ^ Uri.pct_encode ~component:`Host path ^ target

let client ~sw env =
  Spindle_client.create ~sw ~net:(Eio.Stdenv.net env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ()

let opened = function
  | Ok socket -> socket
  | Error e ->
      Alcotest.failf "the socket did not open: %s"
        (Spindle.Server.Unix_socket.error_to_string e)

let serve ~sw env socket routes =
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains:1
        ~read_clock:(fun () -> Ptime.epoch)
        [ socket ] routes;
      `Stop_daemon)

let hello =
  Spindle.get
    Spindle.Path.(s "hello")
    Spindle.Returns.response
    (Spindle.Dep.return (Ok (Spindle.Response.make "hello")))

let echo =
  Spindle.post
    Spindle.Path.(s "echo")
    Spindle.Returns.response
    (Spindle.Dep.map (fun b -> Ok (Spindle.Response.make b)) Spindle.body)

let ( let* ) = Result.bind

type said = { text : string }

let said_json =
  Wiretype.Object.map ~kind:"said" (fun text -> { text })
  |> Wiretype.Object.mem "text" Wiretype.string ~enc:(fun s -> s.text)
  |> Wiretype.Object.finish

let chat =
  Spindle.Websocket.(
    protocol ~client:(json said_json) ~server:(json said_json) ())

let echo_socket =
  Spindle.get
    Spindle.Path.(s "ws")
    (Spindle.Returns.websocket chat)
    (Spindle.Dep.return
       (Ok
          (fun ws ->
            let rec loop () =
              let* said = Spindle.Websocket.receive ws in
              let* () = Spindle.Websocket.send ws said in
              loop ()
            in
            loop ())))

(* {1 The client} *)

(* A server of the test's own on a socket, answering every request with a
   kept connection and counting the connections, and the [Host] of each
   request it reads. *)
let test_a_call_reaches_a_socket () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let path = Filename.concat (private_dir ()) "s.sock" in
  let listening =
    Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:8 (`Unix path)
  in
  let connections = ref 0 and hosts = ref [] in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec accept () =
        Eio.Net.accept_fork ~sw listening
          ~on_error:(fun _ -> ())
          (fun flow _ ->
            incr connections;
            let r = Eio.Buf_read.of_flow flow ~max_size:65536 in
            let rec next () =
              match Spindle_http.Private.Head.Request.read ~max:65536 r with
              | Error _ -> ()
              | Ok (head : Spindle_http.Private.Head.Request.t) ->
                  hosts := Option.value ~default:"-" head.host :: !hosts;
                  Eio.Flow.copy_string
                    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" flow;
                  next ()
            in
            next ());
        accept ()
      in
      accept ());
  let client = client ~sw env in
  let call () =
    match Spindle_client.call client `GET (url_of path "/a?b=1") with
    | Ok r -> check_string "the body" "ok" r.body
    | Error e -> Alcotest.fail (Spindle_client.error_to_string e)
  in
  call ();
  call ();
  check_int "one connection, kept" 1 !connections;
  Alcotest.(check (list string))
    "each request names localhost"
    [ "localhost"; "localhost" ]
    !hosts

let unsent ~naming = function
  | Ok _ -> Alcotest.failf "answered, though nothing should have"
  | Error (`Unsent why) ->
      check_bool
        (Printf.sprintf "%S names %s" why naming)
        true (contains ~sub:naming why)
  | Error e ->
      Alcotest.failf "not Unsent: %s" (Spindle_client.error_to_string e)

let test_an_unreachable_socket_is_unsent () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let dir = private_dir () in
  let client = client ~sw env in
  let missing = Filename.concat dir "missing.sock" in
  unsent ~naming:missing (Spindle_client.call client `GET (url_of missing "/"));
  (* A socket bound and closed leaves its file, which nobody answers. *)
  let dead = Filename.concat dir "dead.sock" in
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_UNIX dead);
  Unix.close fd;
  unsent ~naming:dead (Spindle_client.call client `GET (url_of dead "/"));
  let long = Filename.concat dir (String.make 200 'x') in
  unsent ~naming:long (Spindle_client.call client `GET (url_of long "/"));
  (* A socket in a directory this user may not enter. *)
  let shut = Filename.concat dir "shut" in
  Unix.mkdir shut 0o700;
  let inside = Filename.concat shut "s.sock" in
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_UNIX inside);
  Unix.listen fd 1;
  Unix.chmod shut 0o000;
  Fun.protect
    ~finally:(fun () ->
      Unix.chmod shut 0o700;
      Unix.close fd)
    (fun () ->
      unsent ~naming:inside
        (Spindle_client.call client `GET (url_of inside "/")))

let test_a_websocket_reaches_a_socket () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let path = Filename.concat (private_dir ()) "s.sock" in
  let socket = opened (Spindle.Server.Unix_socket.listen ~sw path) in
  serve ~sw env socket (Spindle.Test.app [ echo_socket ]);
  let got =
    Spindle_client.websocket (client ~sw env) chat
      ("ws+unix://" ^ Uri.pct_encode ~component:`Host path ^ "/ws")
      (fun ws ->
        let* () = Spindle.Websocket.send ws { text = "hi" } in
        let* back = Spindle.Websocket.receive ws in
        Ok back.text)
  in
  match got with
  | Ok text -> check_string "echoed" "hi" text
  | Error e -> Alcotest.fail (Spindle_client.websocket_error_to_string e)

(* {1 The server} *)

let failure = function
  | Ok _ -> Alcotest.fail "opened, though it should be refused"
  | Error (e : Spindle.Server.Unix_socket.error) -> e.failure

let test_the_socket_is_its_owners () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let dir = private_dir () in
  let path = Filename.concat dir "s.sock" in
  Eio.Switch.run (fun sw' ->
      let (_ : _ Eio.Net.listening_socket) =
        opened (Spindle.Server.Unix_socket.listen ~sw:sw' path)
      in
      check_int "the file is 0600" 0o600 (Unix.stat path).st_perm;
      match failure (Spindle.Server.Unix_socket.listen ~sw path) with
      | In_use -> ()
      | f ->
          Alcotest.failf "a live server's path: %s"
            (Spindle.Server.Unix_socket.error_to_string { path; failure = f }));
  check_bool "the file is gone once its switch ends" false
    (Sys.file_exists path);
  (* What a server killed with its socket leaves behind is replaced. *)
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_UNIX path);
  Unix.close fd;
  let (_ : _ Eio.Net.listening_socket) =
    opened (Spindle.Server.Unix_socket.listen ~sw path)
  in
  (* A file that is no socket is the person's, never removed. *)
  let file = Filename.concat dir "notes" in
  Out_channel.with_open_bin file (fun oc -> output_string oc "mine");
  (match failure (Spindle.Server.Unix_socket.listen ~sw file) with
  | Failed _ -> ()
  | f ->
      Alcotest.failf "a file that is no socket: %s"
        (Spindle.Server.Unix_socket.error_to_string
           { path = file; failure = f }));
  check_bool "and is kept" true (Sys.file_exists file);
  let open_dir = Filename.temp_dir ~perms:0o755 "spindle" "" in
  (match
     failure
       (Spindle.Server.Unix_socket.listen ~sw
          (Filename.concat open_dir "s.sock"))
   with
  | Not_private _ -> ()
  | f ->
      Alcotest.failf "a directory others may enter: %s"
        (Spindle.Server.Unix_socket.error_to_string { path; failure = f }));
  match
    failure
      (Spindle.Server.Unix_socket.listen ~sw
         (Filename.concat dir (String.make 200 'x')))
  with
  | Too_long -> ()
  | f ->
      Alcotest.failf "a path too long: %s"
        (Spindle.Server.Unix_socket.error_to_string { path; failure = f })

(* The application's forgery check reads a request over a socket as over
   TCP: a program sends no Origin, and a page of another site is refused. *)
let test_the_applications_checks_hold () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let path = Filename.concat (private_dir ()) "s.sock" in
  let socket = opened (Spindle.Server.Unix_socket.listen ~sw path) in
  serve ~sw env socket (Spindle.Test.app [ hello; echo ]);
  let client = client ~sw env in
  (match Spindle_client.call client `GET (url_of path "/hello") with
  | Ok r -> check_string "a GET is answered" "hello" r.body
  | Error e -> Alcotest.fail (Spindle_client.error_to_string e));
  (match Spindle_client.call client `POST ~body:"hi" (url_of path "/echo") with
  | Ok r ->
      check_int "a POST with no Origin passes" 200
        (Spindle_http.Status.to_int r.status);
      check_string "its body" "hi" r.body
  | Error e -> Alcotest.fail (Spindle_client.error_to_string e));
  match
    Spindle_client.call client `POST ~body:"hi"
      ~headers:[ ("origin", "https://elsewhere.example") ]
      (url_of path "/echo")
  with
  | Ok r ->
      check_int "a foreign Origin is refused" 403
        (Spindle_http.Status.to_int r.status)
  | Error e -> Alcotest.fail (Spindle_client.error_to_string e)

(* {1 MCP over it} *)

let journal = ref [ "first" ]

let lines =
  Mcp.resource "test://journal" ~name:"journal" ~ttl_ms:0
    (Spindle.Dep.return (fun () ->
         Ok [ Mcp.Text (String.concat "\n" !journal) ]))

(* A tool's arguments are an object, here one with no members. *)
let nothing = Wiretype.Object.(map () |> finish)

let ping =
  Mcp.tool "ping" nothing Wiretype.string
    (Spindle.Dep.return (fun () -> Ok "pong"))

let test_mcp_over_a_socket () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let path = Filename.concat (private_dir ()) "s.sock" in
  let socket = opened (Spindle.Server.Unix_socket.listen ~sw path) in
  let changes = Mcp.Changes.create () in
  serve ~sw env socket
    (Spindle.Test.app
       (Mcp.routes ~name:"w" ~version:"1" ~resources:[ lines ] ~changes [ ping ]));
  let mcp = Client.create (client ~sw env) ~url:(url_of path "/mcp") in
  let ok what = function
    | Ok v -> v
    | Error e -> Alcotest.failf "%s: %s" what (Client.error_to_string e)
  in
  let server = ok "discover" (Client.discover mcp) in
  Alcotest.(check (option string)) "its name" (Some "w") server.name;
  Alcotest.(check (list string))
    "its tools" [ "ping" ]
    (List.map (fun (t : Client.tool) -> t.name) (ok "tools" (Client.tools mcp)));
  check_string "a call" "pong"
    (ok "call" (Client.call mcp "ping" nothing () Wiretype.string));
  let read () =
    match ok "read" (Client.read mcp "test://journal") with
    | [ { data = Text t; _ } ] -> t
    | _ -> Alcotest.fail "one text"
  in
  check_string "a read" "first" (read ());
  let told = ref [] in
  let ended =
    ok "listen"
      (Client.listen mcp [ "test://journal" ] (function
        | Acknowledged _ ->
            journal := !journal @ [ "second" ];
            Mcp.Changes.updated changes "test://journal";
            `Continue
        | Updated uri ->
            told := uri :: !told;
            `Stop))
  in
  (match ended with
  | Stopped -> ()
  | Completed | Dropped _ -> Alcotest.fail "the listen ended by itself");
  Alcotest.(check (list string)) "told of the change" [ "test://journal" ] !told;
  check_string "read again" "first\nsecond" (read ())

let () =
  Alcotest.run "unix socket"
    [
      ( "client",
        [
          Alcotest.test_case "a call reaches a socket" `Quick
            test_a_call_reaches_a_socket;
          Alcotest.test_case "an unreachable socket is unsent" `Quick
            test_an_unreachable_socket_is_unsent;
          Alcotest.test_case "a WebSocket reaches a socket" `Quick
            test_a_websocket_reaches_a_socket;
        ] );
      ( "server",
        [
          Alcotest.test_case "the socket is its owner's" `Quick
            test_the_socket_is_its_owners;
          Alcotest.test_case "the application's checks hold" `Quick
            test_the_applications_checks_hold;
        ] );
      ( "mcp",
        [ Alcotest.test_case "over a socket" `Quick test_mcp_over_a_socket ] );
    ]
