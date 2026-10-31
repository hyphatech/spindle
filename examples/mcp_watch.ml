(* Watching a journal as it grows: run mcp_journal, then this, which prints
   each line once, in order, and carries on after a dropped listen without
   losing one. *)

let uri = "haf://intents/0197/journal"

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_client.run env @@ fun client ->
  let clock = Eio.Stdenv.mono_clock env in
  let mcp = Spindle_mcp_client.create client ~url:"http://localhost:8080/mcp" in
  (* The client's own place is the cursor: the next line it has not read. *)
  let next = ref 1 in
  let catch_up () =
    match
      Spindle_mcp_client.read mcp (Printf.sprintf "%s?from=%d" uri !next)
    with
    | Ok contents ->
        List.iter
          (fun (c : Spindle_mcp_client.content) ->
            match c.data with
            | Text line ->
                print_endline line;
                incr next
            | Blob _ -> ())
          contents
    | Error e -> prerr_endline (Spindle_mcp_client.error_to_string e)
  in
  (* Read once acknowledged, so a line written since is not missed, and again
     on each change; a listen dropped is listened again, a second on. *)
  let rec watch () =
    match
      Spindle_mcp_client.listen mcp [ uri ] (fun _ ->
          catch_up ();
          `Continue)
    with
    | Ok (Dropped _) ->
        Eio.Time.Mono.sleep_span clock Mtime.Span.(1 * s);
        watch ()
    | Ok (Completed | Stopped) -> ()
    | Error e -> prerr_endline (Spindle_mcp_client.error_to_string e)
  in
  watch ()
