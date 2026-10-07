let hex_value c =
  match c with
  | '0' .. '9' -> Some (Char.code c - 48)
  | 'a' .. 'f' -> Some (Char.code c - 87)
  | 'A' .. 'F' -> Some (Char.code c - 55)
  | _ -> None

(* The WHATWG percent-decode, after [+] is a space: a [%] that does not
   start two hex digits is kept as it is. *)
let decode s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i < n then
      match s.[i] with
      | '+' ->
          Buffer.add_char b ' ';
          go (i + 1)
      | '%' when i + 2 < n -> (
          match (hex_value s.[i + 1], hex_value s.[i + 2]) with
          | Some h, Some l ->
              Buffer.add_char b (Char.chr ((h * 16) + l));
              go (i + 3)
          | _ ->
              Buffer.add_char b '%';
              go (i + 1))
      | c ->
          Buffer.add_char b c;
          go (i + 1)
  in
  go 0;
  Buffer.contents b

let parse s =
  List.filter_map
    (fun piece ->
      if String.equal piece "" then None
      else
        match String.index_opt piece '=' with
        | None -> Some (decode piece, "")
        | Some i ->
            Some
              ( decode (String.sub piece 0 i),
                decode (String.sub piece (i + 1) (String.length piece - i - 1))
              ))
    (String.split_on_char '&' s)

let encode s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '*' | '-' | '.' | '_') as c ->
          Buffer.add_char b c
      | ' ' -> Buffer.add_char b '+'
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let to_string fields =
  String.concat "&" (List.map (fun (k, v) -> encode k ^ "=" ^ encode v) fields)
