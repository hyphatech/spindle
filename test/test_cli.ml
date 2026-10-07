(* Spindle_cli as a program runs it: cli_app's command line, run as a
   process, read by its exit status and what it wrote. *)

type ran = { status : int; out : string; err : string }

let run args =
  let out_file = Filename.temp_file "cli" ".out"
  and err_file = Filename.temp_file "cli" ".err" in
  let status =
    let out_fd = Unix.openfile out_file [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
    and err_fd = Unix.openfile err_file [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
    let pid =
      Unix.create_process "./cli_app.exe"
        (Array.of_list ("cli_app.exe" :: args))
        Unix.stdin out_fd err_fd
    in
    Unix.close out_fd;
    Unix.close err_fd;
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED n -> n
    | _, (Unix.WSIGNALED n | Unix.WSTOPPED n) ->
        Alcotest.failf "stopped by signal %d" n
  in
  let read f = In_channel.with_open_bin f In_channel.input_all in
  let ran = { status; out = read out_file; err = read err_file } in
  Sys.remove out_file;
  Sys.remove err_file;
  ran

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || go (i + 1))
  in
  go 0

let check_status = Alcotest.(check int)

(* The two committed files, made by the command itself. *)
let with_files f =
  let openapi = Filename.temp_file "openapi" ".json"
  and zod = Filename.temp_file "wire" ".ts" in
  check_status "openapi written" 0
    (run [ "api"; "openapi"; "-o"; openapi ]).status;
  check_status "zod written" 0 (run [ "api"; "zod"; "-o"; zod ]).status;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove openapi;
      Sys.remove zod)
    (fun () -> f ~openapi ~zod)

let test_a_document_is_printed_or_written () =
  let printed = run [ "api"; "openapi" ] in
  check_status "printed" 0 printed.status;
  Alcotest.(check bool)
    "an OpenAPI document" true
    (contains ~sub:{|"openapi"|} printed.out
    && contains ~sub:"/hello" printed.out);
  let zod = run [ "api"; "zod" ] in
  check_status "and the module" 0 zod.status;
  Alcotest.(check bool)
    "headed as generated" true
    (contains ~sub:"Generated from shop's routes" zod.out);
  with_files (fun ~openapi ~zod:_ ->
      Alcotest.(check string)
        "a file holds what was printed" printed.out
        (In_channel.with_open_bin openapi In_channel.input_all))

let test_check_passes_on_what_the_routes_make () =
  with_files (fun ~openapi ~zod ->
      let r = run [ "api"; "check"; "--openapi"; openapi; "--zod"; zod ] in
      check_status "passes" 0 r.status;
      Alcotest.(check bool)
        "and reports what is loose" true
        (contains ~sub:"loose: " r.err))

let test_check_fails_on_a_stale_file () =
  with_files (fun ~openapi ~zod ->
      Out_channel.with_open_bin zod (fun oc ->
          Out_channel.output_string oc "stale");
      let r = run [ "api"; "check"; "--openapi"; openapi; "--zod"; zod ] in
      check_status "fails" 1 r.status;
      Alcotest.(check bool)
        "naming the file" true
        (contains ~sub:(zod ^ " is not what the routes make") r.err))

let test_check_fails_on_a_missing_file () =
  with_files (fun ~openapi ~zod:_ ->
      let r =
        run [ "api"; "check"; "--openapi"; openapi; "--zod"; "/nonexistent.ts" ]
      in
      check_status "fails" 1 r.status;
      Alcotest.(check bool)
        "saying it is missing" true
        (contains ~sub:"/nonexistent.ts is missing" r.err))

let test_strict_fails_on_what_is_loose () =
  with_files (fun ~openapi ~zod ->
      let r =
        run [ "api"; "check"; "--openapi"; openapi; "--zod"; zod; "--strict" ]
      in
      check_status "fails" 1 r.status;
      Alcotest.(check bool)
        "counting the places" true
        (contains ~sub:"described loosely" r.err))

let test_a_command_line_it_cannot_read_is_124 () =
  let r = run [ "api"; "nonsense" ] in
  check_status "cmdliner's status" 124 r.status;
  Alcotest.(check bool) "with its usage" true (contains ~sub:"Usage" r.err)

let () =
  Alcotest.run "cli"
    [
      ( "api",
        [
          Alcotest.test_case "a document is printed or written" `Quick
            test_a_document_is_printed_or_written;
          Alcotest.test_case "check passes on what the routes make" `Quick
            test_check_passes_on_what_the_routes_make;
          Alcotest.test_case "check fails on a stale file" `Quick
            test_check_fails_on_a_stale_file;
          Alcotest.test_case "check fails on a missing file" `Quick
            test_check_fails_on_a_missing_file;
          Alcotest.test_case "--strict fails on what is loose" `Quick
            test_strict_fails_on_what_is_loose;
          Alcotest.test_case "a command line it cannot read is 124" `Quick
            test_a_command_line_it_cannot_read_is_124;
        ] );
    ]
