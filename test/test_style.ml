(* The house rules a reader of the source can check: run by [dune test], so
   CI and an agent find a broken rule as a failing test naming the line. *)

(* Every directory the repository builds. A library's is the one whose dune
   declares a [library]; the rest are executables: tests and examples. *)
let built_dirs =
  [
    "http";
    "core";
    "client";
    "postgres";
    "cli";
    "test";
    "examples";
    "examples/pages";
  ]

let read path = In_channel.with_open_bin path In_channel.input_all

let is_library dir =
  let dune = read (Filename.concat ".." (Filename.concat dir "dune")) in
  List.exists
    (fun line -> String.starts_with ~prefix:"(library" (String.trim line))
    (String.split_on_char '\n' dune)

let dirs = List.filter is_library built_dirs
let executable_dirs = List.filter (fun d -> not (is_library d)) built_dirs

(* An [open] is refused but where it is a module made to be opened: a
   library of combinators or operators, around the expression that uses it --
   Angstrom as [A], a path's [/], a route's metadata, a digest's, a
   statement's shapes -- and Cmdliner's binding operators, file-wide. A span
   is written as OCAML.md writes it, [Mtime.Span.(5 * s)], a module of
   operators opened around the one expression that uses them, in any file. *)
let allowed_opens =
  [
    ("http/accept.ml", "A");
    ("http/auth.ml", "A");
    ("http/cache_control.ml", "A");
    ("http/etag.ml", "A");
    ("http/framing.ml", "A");
    ("http/forwarded.ml", "A");
    ("http/grammar.ml", "A");
    ("http/media_type.ml", "A");
    ("http/multipart.ml", "A");
    ("http/range.ml", "A");
    ("http/structured.ml", "A");
    ("core/files.ml", "Path");
    ("core/files.ml", "Eio.Path");
    ("core/openapi.ml", "Path");
    ("core/static.ml", "Path");
    ("core/static.ml", "Eio.Path");
    ("core/health.ml", "Meta");
    ("core/metrics.ml", "Meta");
    ("core/session.ml", "Digestif.SHA256");
    ("postgres/session.ml", "S");
    ("cli/spindle_cli.ml", "Cmdliner.Term.Syntax");
  ]

let operator_modules = [ "Mtime.Span" ]

(* The names OCAML.md refuses, one per line of the fenced block [name] opens:
   [refused] in every file, [refused-in-a-library] in a library's too. *)
let refusals name =
  let rec skip_to_block = function
    | line :: rest ->
        if String.equal (String.trim line) ("```" ^ name) then names [] rest
        else skip_to_block rest
    | [] -> Error (Printf.sprintf "OCAML.md has no ```%s block" name)
  and names acc = function
    | line :: rest ->
        let line = String.trim line in
        if String.equal line "```" then
          if List.is_empty acc then
            Error (Printf.sprintf "OCAML.md's ```%s block is empty" name)
          else Ok (List.rev acc)
        else if String.equal line "" then names acc rest
        else names (line :: acc) rest
    | [] -> Error (Printf.sprintf "OCAML.md's ```%s block never closes" name)
  in
  skip_to_block (String.split_on_char '\n' (read "../OCAML.md"))

let refused name =
  match refusals name with Ok names -> names | Error m -> Alcotest.fail m

(* A name is read with a leading [Stdlib.] taken off, so [Stdlib.exit] is
   [exit]. *)
let unqualified word =
  if String.starts_with ~prefix:"Stdlib." word then
    String.sub word 7 (String.length word - 7)
  else word

(* The places AGENTS.md allows a refused name, each its file and the name:
   each [invalid_arg] refuses a constant written in source; a server that
   cannot start exits, and says where it listens; the log's default sink
   writes its lines to stderr; and a command line prints its answer and exits
   with its status. *)
let allowed_refused =
  [
    ("core/broadcast.ml", "invalid_arg");
    ("core/compress.ml", "invalid_arg");
    ("core/cookie_repr.ml", "invalid_arg");
    ("core/cors.ml", "invalid_arg");
    ("core/log.ml", "stderr");
    ("core/metrics.ml", "invalid_arg");
    ("core/openapi.ml", "invalid_arg");
    ("core/rate.ml", "invalid_arg");
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

(* What this repository refuses in a library besides OCAML.md's names, and
   why. *)
let refused_here =
  [
    ( "Eio_main.run",
      "a library runs no event loop of its own: take env from its caller" );
    ("Uri.query", "splits a value at commas: use Spindle_http.Urlencoded.parse");
    ( "Uri.get_query_param",
      "splits a value at commas: use Spindle_http.Urlencoded.parse" );
  ]

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
   ([t.open]) begins with a lowercase name and so never matches a refused
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

(* Every file the repository builds, as a path from the root. *)
let built_sources () =
  sources ~dirs:built_dirs ".ml"
  @ sources ~dirs:built_dirs ".mli"
  @ sources ~dirs:executable_dirs ".mlx"

let in_a_library file =
  List.exists (fun dir -> String.equal (Filename.dirname file) dir) dirs

let no_refused_name () =
  let everywhere = refused "refused"
  and in_libraries = refused "refused-in-a-library" in
  let why file word =
    if List.mem word everywhere then Some "refused in every file (OCAML.md)"
    else if not (in_a_library file) then None
    else if List.mem word in_libraries then
      Some "refused in a library (OCAML.md)"
    else List.assoc_opt word refused_here
  in
  let found =
    List.concat_map
      (fun file ->
        identifiers (code_of (read_source file))
        |> List.filter_map (fun (line, word) ->
            let word = unqualified word in
            if
              List.exists
                (fun (f, w) -> String.equal f file && String.equal w word)
                allowed_refused
            then None
            else
              why file word
              |> Option.map (fun why ->
                  Printf.sprintf "%s:%d: %s -- %s" file line word why)))
      (built_sources ())
  in
  Alcotest.(check (list string)) "refused names" [] found

let the_refusals_are_read_from_ocaml_md () =
  let everywhere = refused "refused"
  and in_libraries = refused "refused-in-a-library" in
  List.iter
    (fun name ->
      Alcotest.(check bool) ("refused: " ^ name) true (List.mem name everywhere))
    [ "failwith"; "Unix.sleepf"; "Eio.Time.sleep_until"; "Sys.time" ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        ("refused in a library: " ^ name)
        true
        (List.mem name in_libraries))
    [ "exit"; "Sys.getenv"; "print_endline"; "stderr" ];
  Alcotest.(check bool)
    "a block that is not there is an error" true
    (Result.is_error (refusals "no-such-block"))

(* [Eio.Time.now] is read only as [Ptime.of_float_s (Eio.Time.now clock)],
   the one place a clock becomes an instant. *)
let clock_reads code =
  let n = String.length code in
  let name = "Eio.Time.now" in
  let rec back_over_space i =
    if i >= 0 && (Char.equal code.[i] ' ' || Char.equal code.[i] '\n') then
      back_over_space (i - 1)
    else i
  in
  let made_an_instant i =
    let paren = back_over_space (i - 1) in
    paren >= 0
    && Char.equal code.[paren] '('
    &&
    let last = back_over_space (paren - 1) in
    let from = last - String.length "Ptime.of_float_s" + 1 in
    from >= 0
    && String.equal (String.sub code from (last - from + 1)) "Ptime.of_float_s"
    && (from = 0 || not (is_ident_char code.[from - 1]))
  in
  let rec go i line acc =
    if i >= n then List.rev acc
    else if Char.equal code.[i] '\n' then go (i + 1) (line + 1) acc
    else if
      i + String.length name <= n
      && String.equal (String.sub code i (String.length name)) name
      && (i = 0 || not (is_ident_char code.[i - 1]))
      && (i + String.length name = n
         || not (is_ident_char code.[i + String.length name]))
    then
      go
        (i + String.length name)
        line
        (if made_an_instant i then acc else line :: acc)
    else go (i + 1) line acc
  in
  go 0 1 []

let a_clock_is_read_as_an_instant () =
  let found =
    List.concat_map
      (fun file ->
        List.map
          (fun line ->
            Printf.sprintf
              "%s:%d: Eio.Time.now -- write Ptime.of_float_s (Eio.Time.now \
               clock)"
              file line)
          (clock_reads (code_of (read_source file))))
      (built_sources ())
  in
  Alcotest.(check (list string)) "clock reads" [] found

let a_clock_read_is_found () =
  List.iter
    (fun (source, expected) ->
      Alcotest.(check int) source expected (List.length (clock_reads source)))
    [
      ("let t = Ptime.of_float_s (Eio.Time.now clock)", 0);
      ("let t = Ptime.of_float_s\n  (Eio.Time.now env#clock)", 0);
      ("let s = Eio.Time.now clock in Ptime.of_float_s s", 1);
      ("let ms = Eio.Time.now clock *. 1000.", 1);
      ("let t = Eio.Time.now_ptime clock", 0);
    ]

(* A [float] labelled with a unit, [timeout_s : float] or [?wait_ms:float]:
   a duration is an Mtime.Span.t named for what it bounds. Read off the
   code, so a comment or a string may say it. *)
let unit_suffixes = [ "_s"; "_ms"; "_us"; "_ns" ]

let floats_with_a_unit file source =
  let code = code_of source in
  let n = String.length code in
  let is_space c = Char.equal c ' ' || Char.equal c '\n' in
  let word_at i w =
    i + String.length w <= n
    && String.equal (String.sub code i (String.length w)) w
    && (i = 0 || not (is_ident_char code.[i - 1]))
    && (i + String.length w = n
       || not (is_ident_char code.[i + String.length w]))
  in
  let rec back_over_space i =
    if i >= 0 && is_space code.[i] then back_over_space (i - 1) else i
  in
  let label_before i =
    let colon = back_over_space (i - 1) in
    if colon >= 0 && Char.equal code.[colon] ':' then (
      let last = back_over_space (colon - 1) in
      let first = ref last in
      while !first >= 0 && is_ident_char code.[!first] do
        decr first
      done;
      if last > !first then Some (String.sub code (!first + 1) (last - !first))
      else None)
    else None
  in
  let line_of i =
    let l = ref 1 in
    for x = 0 to i - 1 do
      if Char.equal code.[x] '\n' then incr l
    done;
    !l
  in
  let rec go i acc =
    if i >= n then List.rev acc
    else if word_at i "float" then
      match label_before i with
      | Some label
        when List.exists
               (fun suffix -> String.ends_with ~suffix label)
               unit_suffixes ->
          go (i + 5)
            (Printf.sprintf
               "%s:%d: %s : float -- a duration is an Mtime.Span.t named for \
                what it bounds"
               file (line_of i) label
            :: acc)
      | Some _ | None -> go (i + 5) acc
    else go (i + 1) acc
  in
  go 0 []

let no_float_with_a_unit () =
  let found =
    List.concat_map
      (fun file -> floats_with_a_unit file (read_source file))
      (built_sources ())
  in
  Alcotest.(check (list string)) "floats labelled with a unit" [] found

let a_float_with_a_unit_is_found () =
  let found source = List.length (floats_with_a_unit "row.ml" source) in
  List.iter
    (fun source -> Alcotest.(check int) source 1 (found source))
    [
      "val connect : ?timeout_s:float -> unit";
      "type t = { wait_ms : float option }";
      "let f (heartbeat_s : float) = heartbeat_s";
      "val v : timeout_s:\n  float -> t";
    ];
  List.iter
    (fun source -> Alcotest.(check int) source 0 (found source))
    [
      "val connect : ?timeout:Mtime.Span.t -> unit";
      "val ratio : float";
      "(* timeout_s : float *)";
      "let x_s : int = 1";
    ]

(* Every local open, [M.(...)], [M.[...]] or [M.{...}], with its line and
   the module's path: a bracket after a path whose names are capitalised. An
   array's or a string's index follows a value's name, which is not. An
   operator reached by its path, [M.( + )], is matched too; bind it to a
   name. *)
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
      while
        !j > 0 && (is_name_char code.[!j - 1] || Char.equal code.[!j - 1] '.')
      do
        decr j
      done;
      let path = String.sub code !j (i - !j) in
      let is_module name =
        String.length name > 0
        && match name.[0] with 'A' .. 'Z' -> true | _ -> false
      in
      if String.split_on_char '.' path |> List.for_all is_module then
        go (i + 1) line ((line, path) :: acc)
      else go (i + 1) line acc)
    else go (i + 1) line acc
  in
  go 0 1 []

let no_open_but_the_named () =
  let allowed file name =
    List.mem name operator_modules
    || List.exists
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
      (sources ".ml" @ sources ".mli")
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
      (sources ".ml" @ sources ".mli")
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
   implementation, and no source names one. A package is its name or one of
   its parts ([cohttp-eio], [h2.eio]); a module is its name or one made after
   it ([Cohttp_eio]), but for [Http], since [Http_1_1] is a version here. *)
let http_packages =
  [ "cohttp"; "http"; "httpun"; "httpaf"; "h1"; "h2"; "piaf"; "paf"; "ezcurl" ]

let names_package word package =
  String.equal word package
  || String.starts_with ~prefix:(package ^ "-") word
  || String.starts_with ~prefix:(package ^ ".") word

let names_module word package =
  let name = String.capitalize_ascii package in
  String.equal word name
  || String.starts_with ~prefix:(name ^ "_") word
     && not (String.equal package "http")

let no_other_http_library () =
  let found =
    List.concat_map
      (fun dir ->
        let words =
          String.split_on_char ' '
            (String.map
               (function '(' | ')' | '\n' | '\t' -> ' ' | c -> c)
               (code_of_dune (read_source (Filename.concat dir "dune"))))
        in
        List.filter_map
          (fun package ->
            if List.exists (fun word -> names_package word package) words then
              Some (Printf.sprintf "%s/dune links %s" dir package)
            else None)
          http_packages)
      dirs
    @ List.concat_map
        (fun file ->
          identifiers (code_of (read_source file))
          |> List.filter_map (fun (line, word) ->
              let first =
                match String.index_opt word '.' with
                | Some i -> String.sub word 0 i
                | None -> word
              in
              List.find_opt
                (fun package -> names_module first package)
                http_packages
              |> Option.map (fun package ->
                  Printf.sprintf "%s:%d: %s names %s" file line word package)))
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

(* An example is built so a page cannot show code that does not compile, and
   one no page includes is code nobody reads: every name examples/dune
   builds is included somewhere under docs/. *)
let every_example_is_on_a_page () =
  let words =
    String.split_on_char '\n' (read "../examples/dune")
    |> List.concat_map (String.split_on_char ' ')
    |> List.filter (fun w -> not (String.equal w ""))
  in
  let rec names = function
    | "(names" :: rest -> listed rest
    | _ :: rest -> names rest
    | [] -> []
  and listed = function
    | w :: rest -> (
        match String.index_opt w ')' with
        | Some i -> [ String.sub w 0 i ]
        | None -> w :: listed rest)
    | [] -> []
  in
  let built = names words in
  let rec pages dir =
    Sys.readdir dir |> Array.to_list
    |> List.concat_map (fun f ->
        let path = Filename.concat dir f in
        if Sys.is_directory path then pages path
        else if Filename.check_suffix f ".md" then [ read path ]
        else [])
  in
  let docs = String.concat "\n" (pages "../docs") in
  Alcotest.(check bool)
    "examples/dune names its programs" true
    (List.length built > 1);
  Alcotest.(check (list string))
    "built, and on no page" []
    (List.filter
       (fun name -> not (contains docs (Printf.sprintf {|--8<-- "%s.ml|} name)))
       built)

let () =
  Alcotest.run "style"
    [
      ( "libraries",
        [
          Alcotest.test_case "no refused name" `Quick no_refused_name;
          Alcotest.test_case "the refusals are read from OCAML.md" `Quick
            the_refusals_are_read_from_ocaml_md;
          Alcotest.test_case "a clock is read as an instant" `Quick
            a_clock_is_read_as_an_instant;
          Alcotest.test_case "a clock read is found" `Quick
            a_clock_read_is_found;
          Alcotest.test_case "no float labelled with a unit" `Quick
            no_float_with_a_unit;
          Alcotest.test_case "a float labelled with a unit is found" `Quick
            a_float_with_a_unit_is_found;
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
      ( "documents",
        [
          Alcotest.test_case "every example is on a page" `Quick
            every_example_is_on_a_page;
        ] );
    ]
