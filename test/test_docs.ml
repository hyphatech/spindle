(* An example is built so a page cannot show code that does not compile, and
   one no page imports is code nobody reads: every name examples/dune builds,
   and every module beside them, is imported whole by some page of the site,
   as @examples/<file>.ml?raw. *)

let read path = In_channel.with_open_bin path In_channel.input_all

let contains s sub =
  let n = String.length sub in
  let rec at i =
    i + n <= String.length s
    && (String.equal (String.sub s i n) sub || at (i + 1))
  in
  at 0

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
  let modules =
    Sys.readdir "../examples" |> Array.to_list
    |> List.filter_map (fun f -> Filename.chop_suffix_opt ~suffix:".ml" f)
    (* dune writes the preprocessed x.pp.ml beside each, which no page shows. *)
    |> List.filter (fun m -> not (String.contains m '.'))
  in
  let shown = List.sort_uniq String.compare (built @ modules) in
  let rec pages dir =
    Sys.readdir dir |> Array.to_list
    |> List.concat_map (fun f ->
        let path = Filename.concat dir f in
        if Sys.is_directory path then pages path
        else if Filename.check_suffix f ".md" || Filename.check_suffix f ".mdx"
        then [ read path ]
        else [])
  in
  let docs = String.concat "\n" (pages "../docs/src/content") in
  Alcotest.(check bool)
    "examples/dune names its programs" true
    (List.length built > 1);
  Alcotest.(check (list string))
    "built, and on no page" []
    (List.filter
       (fun name ->
         not (contains docs (Printf.sprintf {|"@examples/%s.ml?raw"|} name)))
       shown)

let () =
  Alcotest.run "docs"
    [
      ( "documents",
        [
          Alcotest.test_case "every example is on a page" `Quick
            every_example_is_on_a_page;
        ] );
    ]
