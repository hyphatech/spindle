(* RFC 7578's multipart/form-data over RFC 2046's boundaries, as
   Spindle_http.Multipart reads it: a row per requirement it meets, named by
   its section, each read whole, a byte at a time, and at cuts a generator
   chooses -- since a boundary split across two reads is where a reader of
   this goes wrong. *)

module M = Spindle_http.Multipart
module G = QCheck.Gen

(* How a body reaches the reader. *)
type delivery = Whole | Bytewise | At of int list

let pieces delivery s =
  match delivery with
  | Whole -> [ s ]
  | Bytewise -> List.init (String.length s) (fun i -> String.make 1 s.[i])
  | At cuts ->
      let cuts =
        List.sort_uniq Int.compare
          (List.filter (fun c -> c > 0 && c < String.length s) cuts)
      in
      let rec go from = function
        | [] -> [ String.sub s from (String.length s - from) ]
        | c :: rest -> String.sub s from (c - from) :: go c rest
      in
      go 0 cuts

let text_plain =
  { Spindle_http.Media_type.type_ = "text"; subtype = "plain"; parameters = [] }

(* Every part, as [name|filename|content_type|content], or the refusal. *)
let read ?(max_head = 1024) ~boundary delivery s =
  let queue = ref (pieces delivery s) in
  let reader =
    M.create ~max_head ~boundary (fun () ->
        match !queue with
        | [] -> Ok None
        | p :: rest ->
            queue := rest;
            Ok (Some p))
  in
  let rec content b =
    match M.read reader with
    | Ok (`Data d) ->
        Buffer.add_string b d;
        content b
    | Ok `End -> Ok (Buffer.contents b)
    | Error e -> Error e
  in
  let rec each acc =
    match M.next reader with
    | Ok None -> Ok (List.rev acc)
    | Ok (Some (p : M.part)) -> (
        match content (Buffer.create 16) with
        | Ok c ->
            each
              (String.concat "|"
                 [
                   p.name;
                   Option.value p.filename ~default:"-";
                   Result.value ~default:"?"
                     (Spindle_http.Media_type.to_string p.content_type);
                   c;
                 ]
              :: acc)
        | Error e -> Error e)
    | Error e -> Error e
  in
  match each [] with
  | Ok parts -> String.concat " ; " parts
  | Error (M.Malformed _) -> "refused"
  | Error M.Head_too_large -> "head too large"
  | Error (M.Source ()) -> "source"

type row = {
  rfc : string;
  says : string;
  boundary : string;
  bytes : string;
  owes : string;
}

let row rfc says ?(boundary = "b") bytes owes =
  { rfc; says; boundary; bytes; owes }

let rows =
  [
    row "7578 §4.1" "each part between boundaries, the last closed with --"
      "--b\r\n\
       Content-Disposition: form-data; name=\"a\"\r\n\
       \r\n\
       one\r\n\
       --b\r\n\
       Content-Disposition: form-data; name=\"b\"\r\n\
       \r\n\
       two\r\n\
       --b--\r\n"
      "a|-|text/plain|one ; b|-|text/plain|two";
    row "2046 §5.1.1" "a preamble before the first boundary is passed over"
      "ignore me\r\n\
       --b\r\n\
       Content-Disposition: form-data; name=\"a\"\r\n\
       \r\n\
       x\r\n\
       --b--"
      "a|-|text/plain|x";
    row "2046 §5.1.1" "an epilogue after the last is passed over"
      "--b\r\n\
       Content-Disposition: form-data; name=\"a\"\r\n\
       \r\n\
       x\r\n\
       --b--\r\n\
       and this\r\n\
       --b\r\n"
      "a|-|text/plain|x";
    row "2046 §5.1.1" "the padding after a boundary is ignored"
      "--b  \t\r\n\
       Content-Disposition: form-data; name=\"a\"\r\n\
       \r\n\
       x\r\n\
       --b \r\n\
       Content-Disposition: form-data; name=\"c\"\r\n\
       \r\n\
       y\r\n\
       --b--"
      "a|-|text/plain|x ; c|-|text/plain|y";
    row "2046 §5.1.1" "the line end before a boundary is the boundary's"
      "--b\r\n\
       Content-Disposition: form-data; name=\"a\"\r\n\
       \r\n\
       line\r\n\
       \r\n\
       --b--"
      "a|-|text/plain|line\r\n";
    row "2046 §5.1.1" "the boundary's text inside a line is content"
      "--b\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx--b y\r\n--b--"
      "a|-|text/plain|x--b y";
    row "2046 §5.1" "a boundary followed by more than padding is no boundary"
      "--b\r\n\
       Content-Disposition: form-data; name=\"a\"\r\n\
       \r\n\
       x\r\n\
       --bz\r\n\
       --b--"
      "refused";
    row "2046 §5.1.1" "a body that ends before its last boundary is refused"
      "--b\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx" "refused";
    row "2046 §5.1.1" "a body with no boundary at all is refused" "just text"
      "refused";
    row "7578 §4.1" "a form of no fields is its closing boundary" "--b--\r\n" "";
    row "7578 §4.2" "every part is form-data"
      "--b\r\nContent-Disposition: attachment; name=\"a\"\r\n\r\nx\r\n--b--"
      "refused";
    row "7578 §4.2" "and names its field"
      "--b\r\nContent-Disposition: form-data\r\n\r\nx\r\n--b--" "refused";
    row "7578 §4.2" "a part with no head at all is refused"
      "--b\r\n\r\nx\r\n--b--" "refused";
    row "7578 §4.2" "a file's name, and filename* not read"
      "--b\r\n\
       Content-Disposition: form-data; name=\"f\"; filename=\"a.txt\"; \
       filename*=UTF-8''b.txt\r\n\
       Content-Type: text/csv\r\n\
       \r\n\
       q,r\r\n\
       --b--"
      "f|a.txt|text/csv|q,r";
    row "7578 §4.4" "a type no reader can read is bytes of no kind"
      "--b\r\n\
       Content-Disposition: form-data; name=\"f\"; filename=\"a\"\r\n\
       Content-Type: not a type\r\n\
       \r\n\
       x\r\n\
       --b--"
      "f|a|application/octet-stream|x";
    row "6838 §4.3" "a parameter given twice is refused, so no reader picks one"
      "--b\r\n\
       Content-Disposition: form-data; name=\"a\"; NAME=\"b\"\r\n\
       \r\n\
       x\r\n\
       --b--"
      "refused";
    row "7578 §4.2" "a parameter's name is compared without case"
      "--b\r\nContent-Disposition: form-data; NAME=\"a\"\r\n\r\nx\r\n--b--"
      "a|-|text/plain|x";
    row "9110 §5.6.4" "a quoted name keeps what it quotes"
      "--b\r\n\
       Content-Disposition: form-data; name=\"a \\\"q\\\" ; b\"\r\n\
       \r\n\
       x\r\n\
       --b--"
      "a \"q\" ; b|-|text/plain|x";
    row "9112 §5.2" "a folded head line is refused"
      "--b\r\nContent-Disposition: form-data;\r\n name=\"a\"\r\n\r\nx\r\n--b--"
      "refused";
    row "9112 §2.2" "a head's lines end at CRLF, and a bare LF is refused"
      "--b\r\n\
       Content-Disposition: form-data; name=\"a\"\n\
       X-Y: z\r\n\
       \r\n\
       x\r\n\
       --b--"
      "refused";
    row "7578 §4.1" "a boundary of RFC 2046's characters"
      ~boundary:"----=_x'()+_,-./:=?"
      "------=_x'()+_,-./:=?\r\n\
       Content-Disposition: form-data; name=\"a\"\r\n\
       \r\n\
       x\r\n\
       ------=_x'()+_,-./:=?--"
      "a|-|text/plain|x";
  ]

let check_row r delivery =
  Alcotest.(check string)
    r.says r.owes
    (read ~boundary:r.boundary delivery r.bytes)

let row_case r =
  Alcotest.test_case
    (r.rfc ^ ": " ^ r.says)
    `Quick
    (fun () ->
      check_row r Whole;
      check_row r Bytewise)

let test_every_row_holds_at_any_cut =
  let rows = Array.of_list rows in
  QCheck.Test.make ~count:1000 ~name:"a row, at any cut"
    (QCheck.make
       ~print:(fun (i, cuts) ->
         Printf.sprintf "%s: %s, at %s" rows.(i).rfc rows.(i).says
           (String.concat "," (List.map string_of_int cuts)))
       G.(
         int_bound (Array.length rows - 1) >>= fun i ->
         map
           (fun cuts -> (i, cuts))
           (list_size (0 -- 8) (0 -- String.length rows.(i).bytes))))
    (fun (i, cuts) ->
      let r = rows.(i) in
      let got = read ~boundary:r.boundary (At cuts) r.bytes in
      String.equal got r.owes
      || QCheck.Test.fail_reportf "owed %S, read %S" r.owes got)

let test_a_head_past_its_limit_is_refused () =
  let long = String.make 200 'x' in
  Alcotest.(check string)
    "past max_head" "head too large"
    (read ~max_head:64 ~boundary:"b" Bytewise
       ("--b\r\nContent-Disposition: form-data; name=\"a\"\r\nX-Long: " ^ long
      ^ "\r\n\r\nx\r\n--b--"))

let test_a_boundary_is_what_rfc_2046_allows () =
  let of_type v =
    match Spindle_http.Media_type.parse v with
    | Ok m -> M.boundary m
    | Error _ -> None
  in
  Alcotest.(check (option string))
    "quoted" (Some "a b")
    (of_type {|multipart/form-data; boundary="a b"|});
  Alcotest.(check (option string))
    "no longer than seventy" None
    (of_type ("multipart/form-data; boundary=" ^ String.make 71 'a'));
  Alcotest.(check (option string))
    "and not ending in a space" None
    (of_type {|multipart/form-data; boundary="ab "|});
  Alcotest.(check (option string))
    "of its own characters" None
    (of_type {|multipart/form-data; boundary="a@b"|});
  Alcotest.(check (option string))
    "on a multipart type" None
    (of_type "text/plain; boundary=ab")

(* What a browser writes, the reader reads as it was, at any cut. *)
let test_what_is_written_reads_back =
  QCheck.Test.make ~count:300 ~name:"written, then read at any cut"
    (QCheck.make
       ~print:(fun (parts, _) ->
         String.concat ", "
           (List.map (fun (n, c) -> Printf.sprintf "%S=%S" n c) parts))
       G.(
         pair
           (list_size (1 -- 4)
              (pair
                 (string_size ~gen:printable (0 -- 8))
                 (string_size (0 -- 64))))
           (list_size (0 -- 6) nat)))
    (fun (parts, cuts) ->
      let parts =
        List.mapi
          (fun i (n, content) ->
            ( {
                M.name = Printf.sprintf "f%d%s" i n;
                filename = None;
                content_type = text_plain;
                headers = [];
              },
              content ))
          parts
      in
      let boundary = "spindle-boundary-7f3a" in
      let body = M.to_string ~boundary parts in
      let written name =
        String.concat ""
          (List.map
             (function '\n' -> "%0A" | '\r' -> "%0D" | c -> String.make 1 c)
             (List.of_seq (String.to_seq name)))
      in
      let owed =
        String.concat " ; "
          (List.map
             (fun ((p : M.part), c) -> written p.name ^ "|-|text/plain|" ^ c)
             parts)
      in
      let got = read ~max_head:4096 ~boundary (At cuts) body in
      String.equal got owed
      || QCheck.Test.fail_reportf "owed %S, read %S" owed got)

(* A type that could end its line is not written, so whoever chose it starts
   no field of their own. *)
let test_a_written_type_starts_no_field () =
  let part content_type =
    ({ M.name = "a"; filename = None; content_type; headers = [] }, "x")
  in
  let media subtype = { text_plain with subtype } in
  let body =
    M.to_string ~boundary:"b"
      [ part (media "plain\r\nX-Evil: 1"); part (media "csv") ]
  in
  Alcotest.(check string)
    "the one with a line end is left out, the other written"
    "a|-|text/plain|x ; a|-|text/csv|x"
    (read ~boundary:"b" Whole body)

let () =
  Alcotest.run "multipart_rfc"
    [
      ("rows", List.map row_case rows);
      ( "properties",
        [
          QCheck_alcotest.to_alcotest test_every_row_holds_at_any_cut;
          QCheck_alcotest.to_alcotest test_what_is_written_reads_back;
          Alcotest.test_case "a written type starts no field" `Quick
            test_a_written_type_starts_no_field;
          Alcotest.test_case "7578 §4.8: a head past its limit is refused"
            `Quick test_a_head_past_its_limit_is_refused;
          Alcotest.test_case "2046 §5.1.1: a boundary is what it allows" `Quick
            test_a_boundary_is_what_rfc_2046_allows;
        ] );
    ]
