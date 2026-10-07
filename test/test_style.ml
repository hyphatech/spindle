(* The house rules a reader of the source can check: run by [dune test], so
   CI and an agent find a broken rule as a failing test naming the line. *)

(* The libraries' directories. *)
let dirs = [ "http"; "core"; "client"; "postgres"; "cli" ]
let command_dirs = []

(* An [open] is refused but where it is a module made to be opened: a
   library of combinators or operators, around the expression that uses it --
   Angstrom as [A], a path's [/], a route's metadata, a digest's, a
   statement's shapes -- and Cmdliner's binding operators, file-wide. *)
let allowed_opens =
  [
    ("http/accept.ml", "A");
    ("http/auth.ml", "A");
    ("http/cache_control.ml", "A");
    ("http/etag.ml", "A");
    ("http/forwarded.ml", "A");
    ("http/grammar.ml", "A");
    ("http/media_type.ml", "A");
    ("http/multipart.ml", "A");
    ("http/range.ml", "A");
    ("http/structured.ml", "A");
    ("core/files.ml", "Path");
    ("core/openapi.ml", "Path");
    ("core/static.ml", "Path");
    ("core/health.ml", "Meta");
    ("core/metrics.ml", "Meta");
    ("core/session.ml", "SHA256");
    ("postgres/session.ml", "S");
    ("cli/spindle_cli.ml", "Cmdliner.Term.Syntax");
  ]

(* A banned identifier allowed where the [.mli] documents it. Each
   [invalid_arg] refuses a constant written in source, as AGENTS.md lists
   them; a server that cannot start exits, and says where it listens; and a
   command line prints its answer and exits with its status. *)
let allowed_banned =
  [
    ("core/broadcast.ml", "invalid_arg");
    ("core/cookie_repr.ml", "invalid_arg");
    ("core/cors.ml", "invalid_arg");
    ("core/metrics.ml", "invalid_arg");
    ("core/openapi.ml", "invalid_arg");
    ("core/server.ml", "invalid_arg");
    ("core/spindle.ml", "invalid_arg");
    ("core/spindle.ml", "exit");
    ("core/spindle.ml", "Printf.printf");
    ("core/test.ml", "invalid_arg");
    ("postgres/session.ml", "invalid_arg");
    ("postgres/pool.ml", "exit");
    ("cli/spindle_cli.ml", "print_string");
    ("cli/spindle_cli.ml", "print_endline");
    ("cli/spindle_cli.ml", "prerr_endline");
    ("cli/spindle_cli.ml", "exit");
  ]

(* An identifier, dotted path included, and the reason it is refused. *)
let banned =
  [
    ("failwith", "errors are values: return a result");
    ("invalid_arg", "errors are values: only where the .mli documents a raise");
    ("Option.get", "partial: match on the option");
    ("Result.get_ok", "partial: match on the result");
    ("Result.get_error", "partial: match on the result");
    ("List.hd", "partial: match on the list");
    ("List.tl", "partial: match on the list");
    ("List.nth", "partial: use List.nth_opt");
    ("Obj.magic", "unsafe");
    ("compare", "polymorphic: use Int.compare, String.compare, ...");
    ("Stdlib.compare", "polymorphic: use Int.compare, String.compare, ...");
    ("Sys.getenv", "a library reads no environment: take it as an argument");
    ("Sys.getenv_opt", "a library reads no environment: take it as an argument");
    ("Unix.getenv", "a library reads no environment: take it as an argument");
    ("Unix.environment", "a library reads no environment");
    ("print_string", "a library never prints: log through Logs");
    ("print_endline", "a library never prints: log through Logs");
    ("prerr_string", "a library never prints: log through Logs");
    ("prerr_endline", "a library never prints: log through Logs");
    ("Printf.printf", "a library never prints: log through Logs");
    ("Printf.eprintf", "a library never prints: log through Logs");
    ("Format.printf", "a library never prints: log through Logs");
    ("Format.eprintf", "a library never prints: log through Logs");
    ("exit", "a library never exits");
  ]

let read path = In_channel.with_open_bin path In_channel.input_all

(* The source with comments, string literals and character literals blanked
   to spaces, newlines kept, so what is left is code and lines still count. *)
let code_of s =
  let n = String.length s in
  let out = Bytes.of_string s in
  let blank i = if not (Char.equal s.[i] '\n') then Bytes.set out i ' ' in
  let rec string i =
    if i >= n then i
    else (
      blank i;
      match s.[i] with
      | '\\' when i + 1 < n ->
          blank (i + 1);
          string (i + 2)
      | '"' -> i + 1
      | _ -> string (i + 1))
  in
  (* {id|...|id}, with [id] lowercase letters or underscores. *)
  let quoted i =
    let j = ref (i + 1) in
    while !j < n && match s.[!j] with 'a' .. 'z' | '_' -> true | _ -> false do
      incr j
    done;
    if !j < n && Char.equal s.[!j] '|' then (
      let close = "|" ^ String.sub s (i + 1) (!j - i - 1) ^ "}" in
      let k = ref (!j + 1) in
      while
        !k + String.length close <= n
        && not (String.equal (String.sub s !k (String.length close)) close)
      do
        incr k
      done;
      let stop = Int.min n (!k + String.length close) in
      for x = i to stop - 1 do
        blank x
      done;
      Some stop)
    else None
  in
  (* 'x', '\n', '\'' and '\123'; a type variable's quote is left alone. *)
  let char i =
    if i + 2 < n && Char.equal s.[i + 1] '\\' then (
      let j = ref (i + 2) in
      while !j < n && not (Char.equal s.[!j] '\'') do
        incr j
      done;
      if !j - i <= 5 then (
        for x = i to !j do
          blank x
        done;
        Some (!j + 1))
      else None)
    else if i + 2 < n && Char.equal s.[i + 2] '\'' then (
      for x = i to i + 2 do
        blank x
      done;
      Some (i + 3))
    else None
  in
  let rec comment depth i =
    if i >= n then i
    else if i + 1 < n && Char.equal s.[i] '(' && Char.equal s.[i + 1] '*' then (
      blank i;
      blank (i + 1);
      comment (depth + 1) (i + 2))
    else if i + 1 < n && Char.equal s.[i] '*' && Char.equal s.[i + 1] ')' then (
      blank i;
      blank (i + 1);
      if depth = 1 then i + 2 else comment (depth - 1) (i + 2))
    else if Char.equal s.[i] '"' then (
      blank i;
      comment depth (string (i + 1)))
    else (
      blank i;
      comment depth (i + 1))
  in
  let rec go i =
    if i >= n then ()
    else
      match s.[i] with
      | '(' when i + 1 < n && Char.equal s.[i + 1] '*' -> go (comment 0 i)
      | '"' ->
          blank i;
          go (string (i + 1))
      | '{' -> ( match quoted i with Some j -> go j | None -> go (i + 1))
      | '\'' -> ( match char i with Some j -> go j | None -> go (i + 1))
      | _ -> go (i + 1)
  in
  go 0;
  Bytes.to_string out

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' | '.' -> true
  | _ -> false

(* Every identifier, dotted path included, with its line. A field access
   ([t.open]) begins with a lowercase name and so never matches a banned
   path, and a path never ends in a dot. *)
let identifiers code =
  let n = String.length code in
  let rec go i line acc =
    if i >= n then List.rev acc
    else if Char.equal code.[i] '\n' then go (i + 1) (line + 1) acc
    else if is_ident_char code.[i] && not (Char.equal code.[i] '.') then (
      let j = ref i in
      while !j < n && is_ident_char code.[!j] do
        incr j
      done;
      let word = String.sub code i (!j - i) in
      let word =
        if String.ends_with ~suffix:"." word then
          String.sub word 0 (String.length word - 1)
        else word
      in
      go !j line ((line, word) :: acc))
    else go (i + 1) line acc
  in
  go 0 1 []

(* What the build writes beside the source: a preprocessed copy, and the
   reference page's script, which is Scalar's words as one string. *)
let generated file =
  String.ends_with ~suffix:".pp.ml" file
  || String.ends_with ~suffix:".pp.mli" file
  || String.equal file "scalar.ml"

(* Every source file with the given suffix, as a path from the root. *)
let sources ?(dirs = dirs) suffix =
  List.concat_map
    (fun dir ->
      Sys.readdir (Filename.concat ".." dir)
      |> Array.to_list
      |> List.filter (fun file ->
          String.ends_with ~suffix file && not (generated file))
      |> List.sort String.compare
      |> List.map (Filename.concat dir))
    dirs

let read_source file = read (Filename.concat ".." file)

let no_banned_identifier () =
  let found =
    List.concat_map
      (fun file ->
        let code = code_of (read_source file) in
        identifiers code
        |> List.filter (fun (_, word) ->
            not
              (List.exists
                 (fun (f, w) -> String.equal f file && String.equal w word)
                 allowed_banned))
        |> List.filter_map (fun (line, word) ->
            List.assoc_opt word banned
            |> Option.map (fun why ->
                Printf.sprintf "%s:%d: %s -- %s" file line word why)))
      (sources ".ml" @ sources ".mli")
  in
  Alcotest.(check (list string)) "banned identifiers" [] found

(* Every local open, [M.(...)], [M.[...]] or [M.{...}], with its line and
   module: a bracket after a path whose last name is capitalised. An array's
   or a string's index follows a value's name, which is not. An operator
   reached by its path, [M.( + )], is matched too; bind it to a name. *)
let local_opens code =
  let n = String.length code in
  let is_name_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> true
    | _ -> false
  in
  let rec go i line acc =
    if i + 1 >= n then List.rev acc
    else if Char.equal code.[i] '\n' then go (i + 1) (line + 1) acc
    else if
      Char.equal code.[i] '.'
      && match code.[i + 1] with '(' | '[' | '{' -> true | _ -> false
    then (
      let j = ref i in
      while !j > 0 && is_name_char code.[!j - 1] do
        decr j
      done;
      match code.[!j] with
      | 'A' .. 'Z' when !j < i ->
          go (i + 1) line ((line, String.sub code !j (i - !j)) :: acc)
      | _ -> go (i + 1) line acc)
    else go (i + 1) line acc
  in
  go 0 1 []

let no_open_but_the_named () =
  let allowed file name =
    List.exists
      (fun (f, m) -> String.equal f file && String.equal m name)
      allowed_opens
  in
  let found =
    List.concat_map
      (fun file ->
        let code = code_of (read_source file) in
        let local =
          List.filter_map
            (fun (line, name) ->
              if allowed file name then None
              else
                Some
                  (Printf.sprintf "%s:%d: %s.( ... ) -- use a module alias" file
                     line name))
            (local_opens code)
        in
        let rec opens = function
          | (line, "open") :: (_, name) :: rest ->
              if allowed file name then opens rest
              else
                Printf.sprintf "%s:%d: open %s -- use a module alias" file line
                  name
                :: opens rest
          | _ :: rest -> opens rest
          | [] -> []
        in
        local @ opens (identifiers code))
      (sources ~dirs:(dirs @ command_dirs) ".ml" @ sources ".mli")
  in
  Alcotest.(check (list string)) "opens" [] found

let no_silenced_warning () =
  let found =
    List.concat_map
      (fun file ->
        let code = code_of (read_source file) in
        String.split_on_char '\n' code
        |> List.mapi (fun i l -> (i + 1, l))
        |> List.filter_map (fun (line, l) ->
            let rec has i =
              i + 8 <= String.length l
              && (String.equal (String.sub l i 8) "@warning" || has (i + 1))
            in
            if has 0 then
              Some
                (Printf.sprintf
                   "%s:%d: a silenced warning is a code shape to fix" file line)
            else None))
      (sources ~dirs:(dirs @ command_dirs) ".ml" @ sources ".mli")
  in
  Alcotest.(check (list string)) "silenced warnings" [] found

(* A dune file with its comments, from a [;] to the end of its line, cut. *)
let code_of_dune s =
  String.split_on_char '\n' s
  |> List.map (fun line ->
      match String.index_opt line ';' with
      | Some i -> String.sub line 0 i
      | None -> line)
  |> String.concat "\n"

let contains s sub =
  let n = String.length sub in
  let rec at i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || at (i + 1))
  in
  at 0

let every_module_has_an_interface () =
  let missing =
    sources ".ml"
    |> List.filter (fun ml ->
        not (Sys.file_exists (Filename.concat ".." (ml ^ "i"))))
    |> List.map (fun ml -> ml ^ " has no .mli")
  in
  Alcotest.(check (list string)) "modules without an interface" [] missing

(* The client links what both ends speak and nothing of the server's, so a
   program that calls other servers links no framework. *)
let the_client_links_no_framework () =
  let words =
    String.split_on_char ' '
      (String.map
         (function '(' | ')' | '\n' | '\t' -> ' ' | c -> c)
         (code_of_dune (read_source "client/dune")))
  in
  Alcotest.(check bool)
    "it links spindle_http" true
    (List.mem "spindle_http" words);
  Alcotest.(check bool) "and not spindle" false (List.mem "spindle" words)

(* Spindle reads and writes HTTP/1.1 itself: no library links another HTTP
   implementation, and no source names one. *)
let no_other_http_library () =
  let found =
    List.concat_map
      (fun dir ->
        let dune = code_of_dune (read_source (Filename.concat dir "dune")) in
        if contains dune "cohttp" || contains dune " http\n" then
          [ dir ^ "/dune links an HTTP library" ]
        else [])
      dirs
    @ List.concat_map
        (fun file ->
          let code = code_of (read_source file) in
          List.filter_map
            (fun word ->
              if contains code word then Some (file ^ " names " ^ word)
              else None)
            [ "Cohttp"; "Http." ])
        (sources ".ml" @ sources ".mli")
  in
  Alcotest.(check (list string)) "other HTTP libraries" [] found

(* The driver is reached through rowtype's Postgres backend alone, so a
   second driver is a second backend and no change here. *)
let names_no_driver () =
  let found =
    List.concat_map
      (fun file ->
        let text = read_source file in
        List.filter_map
          (fun word ->
            if contains text word then Some (file ^ " names " ^ word) else None)
          [ "Postgres_eio"; "postgres_eio"; "postgres-eio" ])
      (sources ".ml" @ sources ".mli"
      @ List.map (fun dir -> Filename.concat dir "dune") dirs)
  in
  Alcotest.(check (list string)) "the driver" [] found

let () =
  Alcotest.run "style"
    [
      ( "libraries",
        [
          Alcotest.test_case "no banned identifier" `Quick no_banned_identifier;
          Alcotest.test_case "no open but the named" `Quick
            no_open_but_the_named;
          Alcotest.test_case "no silenced warning" `Quick no_silenced_warning;
          Alcotest.test_case "every module has an interface" `Quick
            every_module_has_an_interface;
        ] );
      ( "boundaries",
        [
          Alcotest.test_case "the client links no framework" `Quick
            the_client_links_no_framework;
          Alcotest.test_case "no other HTTP library" `Quick
            no_other_http_library;
          Alcotest.test_case "names no driver" `Quick names_no_driver;
        ] );
    ]
