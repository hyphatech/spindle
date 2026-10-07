let is_token s = String.length s > 0 && String.for_all Grammar.is_tchar s

(* Visible characters, obs-text, space and tab. A control character is how a
   header is smuggled past a reader that stops at it and one that does not. *)
let is_value_char c =
  Char.equal c '\t' || (Char.code c >= 0x20 && Char.code c <> 0x7f)

let is_ows c = Char.equal c ' ' || Char.equal c '\t'

let trim_ows s =
  let n = String.length s in
  let rec first i = if i < n && is_ows s.[i] then first (i + 1) else i in
  let rec last j = if j > 0 && is_ows s.[j - 1] then last (j - 1) else j in
  let i = first 0 in
  let j = last n in
  if j <= i then "" else String.sub s i (j - i)

let parse line =
  if String.length line > 0 && is_ows line.[0] then
    Error "a field folded onto the line before it"
  else
    match String.index_opt line ':' with
    | None -> Error "a field with no colon"
    | Some i ->
        let name = String.sub line 0 i in
        let value = String.sub line (i + 1) (String.length line - i - 1) in
        if not (is_token name) then
          Error (Printf.sprintf "a field name %S" name)
        else if not (String.for_all is_value_char value) then
          Error (Printf.sprintf "a control character in %s" name)
        else Ok (name, trim_ows value)

let unfold (name, value) line =
  let more = trim_ows line in
  if not (String.for_all is_value_char more) then
    Error (Printf.sprintf "a control character in %s" name)
  else if String.equal value "" then Ok (name, more)
  else if String.equal more "" then Ok (name, value)
  else Ok (name, value ^ " " ^ more)

let is_text s = String.for_all is_value_char s

(* A sender generates only what the grammar allows (RFC 9110 §2.2). *)
let is_writable (name, value) =
  is_token name && String.for_all is_value_char value

let caseless_equal a b =
  let n = String.length a in
  n = String.length b
  &&
  let rec from i =
    i = n
    || Char.equal (Char.lowercase_ascii a.[i]) (Char.lowercase_ascii b.[i])
       && from (i + 1)
  in
  from 0

let has_name name (k, _) = caseless_equal k name

let find fields name =
  let has_name = has_name name in
  List.find_map
    (fun ((_, v) as f) -> if has_name f then Some v else None)
    fields

let all fields name =
  let has_name = has_name name in
  List.filter_map
    (fun ((_, v) as f) -> if has_name f then Some v else None)
    fields

(* Split at commas outside quoted strings (RFC 9110 §5.6.1); an unclosed
   quote holds the rest of the value. *)
let elements value =
  let pieces = ref [] and start = ref 0 in
  let cut i =
    pieces := String.sub value !start (i - !start) :: !pieces;
    start := i + 1
  in
  let rec outside_quotes i =
    if i < String.length value then
      match value.[i] with
      | ',' ->
          cut i;
          outside_quotes (i + 1)
      | '"' -> inside_quotes (i + 1)
      | _ -> outside_quotes (i + 1)
  and inside_quotes i =
    if i < String.length value then
      match value.[i] with
      | '"' -> outside_quotes (i + 1)
      | '\\' -> inside_quotes (i + 2)
      | _ -> inside_quotes (i + 1)
  in
  outside_quotes 0;
  cut (String.length value);
  List.rev !pieces
  |> List.filter_map (fun e -> match trim_ows e with "" -> None | e -> Some e)

let quoted s =
  if is_token s then s
  else
    let b = Buffer.create (String.length s + 2) in
    Buffer.add_char b '"';
    String.iter
      (fun c ->
        (match c with '"' | '\\' -> Buffer.add_char b '\\' | _ -> ());
        Buffer.add_char b c)
      s;
    Buffer.add_char b '"';
    Buffer.contents b

let has_element fields name e =
  let e = String.lowercase_ascii e in
  List.exists
    (fun v ->
      List.exists
        (fun e' -> String.equal (String.lowercase_ascii e') e)
        (elements v))
    (all fields name)

let line ic =
  match Eio.Buf_read.take_while (fun c -> not (Char.equal c '\n')) ic with
  | exception Eio.Buf_read.Buffer_limit_exceeded -> Error `Too_long
  | l -> (
      match Eio.Buf_read.char '\n' ic with
      | exception End_of_file -> Error `Closed
      | () ->
          let n = String.length l in
          if n = 0 || not (Char.equal l.[n - 1] '\r') then Error `Bare_lf
          else
            let l = String.sub l 0 (n - 1) in
            if String.contains l '\r' then Error `Bare_cr else Ok l)
