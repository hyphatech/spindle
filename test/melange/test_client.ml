(* The printed client against the real server: app.ml served on a port the
   system chose, and run.js -- the printed module and its cases, compiled by
   Melange -- run by Bun against it. Its cases are its own to report; this
   suite holds its exit. *)

let serve ~sw env =
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
        ~read_clock:(fun () -> Ptime.epoch)
        ~drain:Mtime.Span.(100 * ms)
        [ socket ] App.app;
      `Stop_daemon);
  port

let test_every_route_from_the_browser env () =
  Eio.Switch.run @@ fun sw ->
  let port = serve ~sw env in
  match
    Eio.Process.run
      (Eio.Stdenv.process_mgr env)
      [
        "bun";
        "out/test/melange/run.js";
        Printf.sprintf "http://127.0.0.1:%d" port;
      ]
  with
  | () -> ()
  | exception Eio.Exn.Io (Eio.Process.E (Eio.Process.Child_error status), _) ->
      Alcotest.failf "the cases failed: %a" Eio.Process.pp_status status

let () =
  Eio_main.run @@ fun env ->
  Alcotest.run "melange"
    [
      ( "client",
        [
          Alcotest.test_case "every route, from the browser's runtime" `Quick
            (test_every_route_from_the_browser env);
        ] );
    ]
