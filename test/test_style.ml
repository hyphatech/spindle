(* The house rules a reader of the source can check: run by [dune test], so
   CI and an agent find a broken rule as a failing test naming the line. *)

(* The places AGENTS.md allows a refused name, each its file and the name,
   and only there: by "No partial functions, and [invalid_arg] only where
   the [.mli] says it raises", each [invalid_arg] refuses a constant written
   in source; and by "A library prints and exits only where its [.mli]
   says, and these are the places", a server that cannot start exits and
   says where it listens, the log's default sink writes its lines to
   stderr, and a command line prints its answer and exits with its
   status. *)
let allowed =
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
let read path = In_channel.with_open_bin path In_channel.input_all
let read_source file = read (Filename.concat ".." file)

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
   path, and a path never ends in a dot. A labelled argument's label
   ([~stdout:]) names no value and is left out. *)
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
      let label =
        i > 0
        && (Char.equal code.[i - 1] '~' || Char.equal code.[i - 1] '?')
        && !j < n
        && Char.equal code.[!j] ':'
      in
      go !j line (if label then acc else (line, word) :: acc))
    else go (i + 1) line acc
  in
  go 0 1 []

(* A dune file's atoms, each bracket one of its own, its comments, from a
   [;] to the end of its line, cut. *)
let atoms_of_dune s =
  String.split_on_char '\n' s
  |> List.concat_map (fun line ->
      let code =
        match String.index_opt line ';' with
        | Some i -> String.sub line 0 i
        | None -> line
      in
      String.split_on_char ' '
        (String.concat " ( "
           (String.split_on_char '('
              (String.concat " ) " (String.split_on_char ')' code)))))
  |> List.concat_map (String.split_on_char '\t')
  |> List.filter (fun atom -> not (String.equal atom ""))

(* The kinds of a dune file's stanzas, in order: [library], [rule]. *)
let stanzas_of_dune s =
  let rec go depth = function
    | "(" :: kind :: rest when depth = 0 -> kind :: go 1 rest
    | "(" :: rest -> go (depth + 1) rest
    | ")" :: rest -> go (depth - 1) rest
    | _ :: rest -> go depth rest
    | [] -> []
  in
  go 0 (atoms_of_dune s)

(* The files a dune file's rules write, named in a [target] or [targets]
   field: the build's, not the source's. *)
let targets_of_dune s =
  let rec go = function
    | "(" :: ("target" | "targets") :: rest -> names rest
    | _ :: rest -> go rest
    | [] -> []
  and names = function
    | ")" :: rest -> go rest
    | name :: rest -> name :: names rest
    | [] -> []
  in
  go (atoms_of_dune s)

(* A directory dune builds, as a path from the root, and the kinds of the
   stanzas its [dune] declares. *)
type place = { dir : string; stanzas : string list }

(* A library's directory is one whose [dune] declares a [library]; any
   other builds an executable: a command, a test or an example. *)
let library place = List.mem "library" place.stanzas
let builds = [ "library"; "executable"; "executables"; "test"; "tests" ]

(* Every directory the build reads, from the root: dune skips a directory
   whose name starts with [.] or [_], [_build], [_opam] and [.claude]
   among them. *)
let rec directories dir =
  Sys.readdir (Filename.concat ".." dir)
  |> Array.to_list |> List.sort String.compare
  |> List.concat_map (fun name ->
      let path =
        if String.equal dir "" then name else Filename.concat dir name
      in
      if
        Sys.is_directory (Filename.concat ".." path)
        && (not (String.starts_with ~prefix:"." name))
        && not (String.starts_with ~prefix:"_" name)
      then path :: directories path
      else [])

let places () =
  List.filter_map
    (fun dir ->
      let dune = Filename.concat (Filename.concat ".." dir) "dune" in
      match Sys.file_exists dune with
      | false -> None
      | true ->
          let stanzas = stanzas_of_dune (read dune) in
          if List.exists (fun kind -> List.mem kind builds) stanzas then
            Some { dir; stanzas }
          else None)
    ("" :: directories "")

(* Every [.ml] and [.mli] a place holds, as a path from the root, but what
   its rules write and a preprocessor's copy. *)
let files_of place =
  let generated =
    targets_of_dune (read_source (Filename.concat place.dir "dune"))
  in
  Sys.readdir (Filename.concat ".." place.dir)
  |> Array.to_list
  |> List.filter (fun file ->
      (String.ends_with ~suffix:".ml" file
      || String.ends_with ~suffix:".mli" file)
      && (not (String.ends_with ~suffix:".pp.ml" file))
      && (not (String.ends_with ~suffix:".pp.mli" file))
      && not (List.mem file generated))
  |> List.sort String.compare
  |> List.map (Filename.concat place.dir)

let every_file () = List.concat_map files_of (places ())

(* A name is read with a leading [Stdlib.] taken off, so [Stdlib.exit] is
   [exit]. *)
let unqualified word =
  match String.starts_with ~prefix:"Stdlib." word with
  | true -> String.sub word 7 (String.length word - 7)
  | false -> word

(* The names of a block of [markdown] fenced as [fence], one a line, each
   with a leading [Stdlib.] taken off; none when there is no such block. *)
let fenced fence markdown =
  let rec outside = function
    | [] -> []
    | l :: rest when String.equal (String.trim l) ("```" ^ fence) -> inside rest
    | _ :: rest -> outside rest
  and inside = function
    | [] -> []
    | l :: _ when String.equal (String.trim l) "```" -> []
    | l :: rest -> (
        match String.trim l with
        | "" -> inside rest
        | name -> unqualified name :: inside rest)
  in
  outside (String.split_on_char '\n' markdown)

(* OCAML.md's three lists, read from its copy at the root, so no list is
   kept here: every file refuses the names in [refused], a library's also
   those in [refused-in-a-library], and every file but a library's clock
   module, [instant.ml], those in [only-in-the-clock-module]. A block that
   cannot be found fails every test that reads it rather than refusing
   nothing. *)
type refusals = {
  refused : string list;
  only_in_the_clock_module : string list;
  in_a_library : string list;
}

let refusals () =
  let markdown = read_source "OCAML.md" in
  let block fence =
    match fenced fence markdown with
    | [] -> Alcotest.failf "OCAML.md has no names in a block fenced as %s" fence
    | names -> names
  in
  {
    refused = block "refused";
    only_in_the_clock_module = block "only-in-the-clock-module";
    in_a_library = block "refused-in-a-library";
  }

(* Each name of [names] in [source], a file's text, as a line naming it and
   [why], but where [allowed] allows it in that file. *)
let refused_in ~names ~why file source =
  identifiers (code_of source)
  |> List.filter (fun (_, word) ->
      let name = unqualified word in
      List.mem name names
      && not
           (List.exists
              (fun (f, n) -> String.equal f file && String.equal n name)
              allowed))
  |> List.map (fun (line, word) ->
      Printf.sprintf "%s:%d: %s -- %s" file line (unqualified word) why)

(* Each refused name in [source], the text of [file] in [place], held to the
   lists its place takes: a library's [instant.ml] is its clock module,
   where time crosses to the two calls that have no typed form. *)
let refused_names (r : refusals) place file source =
  let clock_module =
    library place && String.equal (Filename.basename file) "instant.ml"
  in
  refused_in ~names:r.refused ~why:"refused by OCAML.md" file source
  @ (if clock_module then []
     else
       refused_in ~names:r.only_in_the_clock_module
         ~why:"only in a library's clock module, instant.ml, by OCAML.md" file
         source)
  @
  if library place then
    refused_in ~names:r.in_a_library ~why:"refused in a library by OCAML.md"
      file source
  else []

let no_refused_name () =
  let r = refusals () in
  let found =
    List.concat_map
      (fun place ->
        List.concat_map
          (fun file -> refused_names r place file (read_source file))
          (files_of place))
      (places ())
  in
  Alcotest.(check (list string)) "refused names" [] found

(* The three blocks are read whole, a name is found bare and behind
   [Stdlib.], a label is no use of the value it is named like, and a dune
   file says which of its directory's files are built and whether it is a
   library's. *)
let the_refusals_are_read () =
  let r = refusals () in
  List.iter
    (fun (names, name) ->
      Alcotest.(check bool) (name ^ " is read") true (List.mem name names))
    [
      (r.refused, "failwith");
      (r.refused, "Unix.sleep");
      (r.refused, "compare");
      (r.only_in_the_clock_module, "Eio.Time.now");
      (r.only_in_the_clock_module, "Unix.sleepf");
      (r.in_a_library, "print_string");
      (r.in_a_library, "exit");
    ];
  Alcotest.(check bool)
    "exit is no refusal outside a library" false
    (List.mem "exit" r.refused);
  Alcotest.(check bool)
    "Unix.sleepf is no refusal in every file" false
    (List.mem "Unix.sleepf" r.refused);
  Alcotest.(check (list string))
    "a block read" [ "exit"; "compare" ]
    (fenced "refused-in-a-library"
       "- a list:\n\n\
       \  ```refused\n\
       \  failwith\n\
       \  ```\n\n\
       \  ```refused-in-a-library\n\
       \  exit\n\n\
       \  Stdlib.compare\n\
       \  ```\n\
        after\n");
  Alcotest.(check (list string))
    "a document with no block" []
    (fenced "refused" "# OCaml\n\n```ocaml\nfailwith\n```\n");
  Alcotest.(check (list string))
    "found"
    [
      "row.ml:1: exit -- refused";
      "row.ml:2: List.hd -- refused";
      "row.ml:3: exit -- refused";
    ]
    (refused_in ~names:[ "exit"; "List.hd" ] ~why:"refused" "row.ml"
       "let _ = Stdlib.exit\nlet _ = List.hd\nlet _ = f ~stdout:a ~exit");
  Alcotest.(check (list string))
    "stanzas"
    [ "library"; "rule"; "executables" ]
    (stanzas_of_dune
       "; (test)\n(library\n (name a))\n(rule (target b.ml))\n(executables)");
  Alcotest.(check (list string))
    "targets" [ "b.ml"; "c.ml"; "d.ml" ]
    (targets_of_dune
       "(rule (target b.ml) (action (with-stdout-to %{target} (run x))))\n\
        (rule (targets c.ml d.ml))")

(* The clock module's names are refused in every file but a library's
   [instant.ml]: in a library's other files, in an [instant.ml] a test or
   a command builds, and in an [.mli] beside the clock module; the other
   lists hold in the clock module as anywhere. *)
let the_clock_module_alone_crosses () =
  let r =
    {
      refused = [ "failwith" ];
      only_in_the_clock_module = [ "Eio.Time.now"; "Unix.sleepf" ];
      in_a_library = [ "exit" ];
    }
  in
  let lib = { dir = "src"; stanzas = [ "library" ] }
  and test = { dir = "test"; stanzas = [ "test" ] } in
  let source =
    "let now c = Eio.Time.now c\nlet sleep s = Unix.sleepf s\nlet _ = failwith"
  in
  let found place file =
    List.map
      (fun l ->
        match String.index_opt l ' ' with
        | Some i -> String.sub l 0 i
        | None -> l)
      (refused_names r place file source)
  in
  Alcotest.(check (list string))
    "in a library's instant.ml" [ "src/instant.ml:3:" ]
    (found lib "src/instant.ml");
  Alcotest.(check (list string))
    "in a library's other file"
    [ "src/log.ml:3:"; "src/log.ml:1:"; "src/log.ml:2:" ]
    (found lib "src/log.ml");
  Alcotest.(check (list string))
    "in a library's instant.mli"
    [ "src/instant.mli:3:"; "src/instant.mli:1:"; "src/instant.mli:2:" ]
    (found lib "src/instant.mli");
  Alcotest.(check (list string))
    "in a test's instant.ml"
    [ "test/instant.ml:3:"; "test/instant.ml:1:"; "test/instant.ml:2:" ]
    (found test "test/instant.ml")

(* Each name ending in a unit, [_s], [_ms], [_us] or [_ns], given the type
   [float], with its line: [x_s : float], [~x_s:float] and
   [~x_s:(x : float)]. A time counted in a bare float is what OCAML.md's
   shared shapes refuse: a [Ptime.t] or an [Mtime.Span.t] says its unit by
   its type. *)
let floats_with_a_unit code =
  let n = String.length code in
  let is_name_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> true
    | _ -> false
  in
  let rec blanks i =
    if
      i < n
      && match code.[i] with ' ' | '\n' | '\t' | '\r' -> true | _ -> false
    then blanks (i + 1)
    else i
  in
  let rec name_end i =
    if i < n && is_name_char code.[i] then name_end (i + 1) else i
  in
  let float_at i =
    i + 5 <= n
    && String.equal (String.sub code i 5) "float"
    && (i + 5 = n || not (is_name_char code.[i + 5]))
  in
  (* A colon that is a type's, not [::] or [:=]. *)
  let colon_at i =
    i < n
    && Char.equal code.[i] ':'
    && not
         (i + 1 < n
         && (Char.equal code.[i + 1] ':' || Char.equal code.[i + 1] '='))
  in
  let typed_float i =
    colon_at i
    &&
    let j = blanks (i + 1) in
    float_at j
    || j < n
       && Char.equal code.[j] '('
       &&
       let k = blanks (name_end (blanks (j + 1))) in
       colon_at k && float_at (blanks (k + 1))
  in
  let rec go i line acc =
    if i >= n then List.rev acc
    else if Char.equal code.[i] '\n' then go (i + 1) (line + 1) acc
    else if is_name_char code.[i] && (i = 0 || not (is_name_char code.[i - 1]))
    then
      let j = name_end i in
      let name = String.sub code i (j - i) in
      let with_unit =
        List.exists
          (fun suffix -> String.ends_with ~suffix name)
          [ "_s"; "_ms"; "_us"; "_ns" ]
      in
      go j line
        (if with_unit && typed_float (blanks j) then (line, name) :: acc
         else acc)
    else go (i + 1) line acc
  in
  go 0 1 []

let no_float_with_a_unit () =
  let found =
    List.concat_map
      (fun file ->
        floats_with_a_unit (code_of (read_source file))
        |> List.map (fun (line, name) ->
            Printf.sprintf
              "%s:%d: %s is a float with a unit -- a time is a Ptime.t or an \
               Mtime.Span.t"
              file line name))
      (every_file ())
  in
  Alcotest.(check (list string)) "floats with a unit" [] found

(* The forms OCAML.md's shared shapes refuse are each found, and a float
   that is no time, or a time that is no float, is not. *)
let every_float_with_a_unit () =
  Alcotest.(check (list string))
    "found"
    [
      "wait_s";
      "timeout_ms";
      "delay_s";
      "after_ms";
      "tick_us";
      "elapsed_ns";
      "timeout_s";
    ]
    (List.map snd
       (floats_with_a_unit
          "val f : wait_s:float -> unit\n\
           let g (timeout_ms : float) = timeout_ms\n\
           let h ?delay_s:(d : float) () = d\n\
           type t = { after_ms : float option }\n\
           val i : tick_us:float -> elapsed_ns:float -> unit\n\
           val v : timeout_s:\n\
          \  float -> t\n\
           let ok (ratio : float) (n_s : int) xs_s = n_s :: xs_s\n\
           let r_s := 1.0\n\
           val connect : ?timeout:Mtime.Span.t -> unit"))

(* What this repository refuses in a library besides OCAML.md's names, each
   with the rule it keeps: OCAML.md's "A library runs no event loop of its
   own", and AGENTS.md's "A value with structure is read by its parser". *)
let refused_here =
  [
    ( "Eio_main.run",
      "a library runs no event loop of its own: take env from its caller" );
    ("Uri.query", "splits a value at commas: use Spindle_http.Urlencoded.parse");
    ( "Uri.get_query_param",
      "splits a value at commas: use Spindle_http.Urlencoded.parse" );
  ]

let no_name_refused_here () =
  let found =
    places () |> List.filter library |> List.concat_map files_of
    |> List.concat_map (fun file ->
        let source = read_source file in
        List.concat_map
          (fun (name, why) -> refused_in ~names:[ name ] ~why file source)
          refused_here)
  in
  Alcotest.(check (list string)) "names refused here" [] found

(* A page written in JSX, an [.mlx], is built as an [.ml] is, and held to
   the same refusals and the same rule on a float with a unit. *)
let no_refused_name_in_jsx () =
  let r = refusals () in
  let found =
    List.concat_map
      (fun place ->
        Sys.readdir (Filename.concat ".." place.dir)
        |> Array.to_list
        |> List.filter (String.ends_with ~suffix:".mlx")
        |> List.sort String.compare
        |> List.concat_map (fun name ->
            let file = Filename.concat place.dir name in
            let source = read_source file in
            refused_names r place file source
            @ List.map
                (fun (line, name) ->
                  Printf.sprintf
                    "%s:%d: %s is a float with a unit -- a time is a Ptime.t \
                     or an Mtime.Span.t"
                    file line name)
                (floats_with_a_unit (code_of source))))
      (places ())
  in
  Alcotest.(check (list string)) "refused names in JSX" [] found

(* Every directory a library is built from, and its files ending in
   [suffix]: the rules on opens, warnings and interfaces, and the
   boundaries, hold for the libraries. *)
let dirs () = places () |> List.filter library |> List.map (fun p -> p.dir)

let sources suffix =
  places () |> List.filter library |> List.concat_map files_of
  |> List.filter (String.ends_with ~suffix)

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
      (dirs ())
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
      @ List.map (fun dir -> Filename.concat dir "dune") (dirs ()))
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
      ( "refusals",
        [
          Alcotest.test_case "no refused name" `Quick no_refused_name;
          Alcotest.test_case "the refusals are read" `Quick
            the_refusals_are_read;
          Alcotest.test_case "the clock module alone crosses" `Quick
            the_clock_module_alone_crosses;
          Alcotest.test_case "no float with a unit" `Quick no_float_with_a_unit;
          Alcotest.test_case "every float with a unit" `Quick
            every_float_with_a_unit;
          Alcotest.test_case "no name refused here" `Quick no_name_refused_here;
          Alcotest.test_case "no refused name in JSX" `Quick
            no_refused_name_in_jsx;
        ] );
      ( "libraries",
        [
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
