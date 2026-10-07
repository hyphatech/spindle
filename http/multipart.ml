module A = Angstrom
module G = Grammar

type part = {
  name : string;
  filename : string option;
  content_type : Media_type.t;
  headers : (string * string) list;
}

let text_plain =
  { Media_type.type_ = "text"; subtype = "plain"; parameters = [] }

let octet_stream =
  {
    Media_type.type_ = "application";
    subtype = "octet-stream";
    parameters = [];
  }

(* A part is text/plain unless it says otherwise (RFC 7578 §4.4), and bytes
   of no kind where what it says cannot be read: a browser sends whatever
   type it guessed for a file, and refusing the form for it would lose the
   file. *)
let content_type_of headers =
  match Field.find headers "content-type" with
  | None -> text_plain
  | Some t -> Result.value (Media_type.parse t) ~default:octet_stream

type 'e error = Malformed of string | Head_too_large | Source of 'e

(* Where the reader stands in RFC 2046's body. *)
type state = Preamble | After_boundary | Part_head | Part_content | Finished

type 'e t = {
  pull : unit -> (string option, 'e) result;
  first_boundary : string;  (** [--boundary] *)
  delimiter : string;  (** [CRLF --boundary], which ends a part's content *)
  max_head : int;
  buffer : Buffer.t;
  mutable position : int;  (** how much of [buffer] is read *)
  mutable source_ended : bool;
  mutable state : state;
}

(* RFC 2046 §5.1.1's bchars: a space anywhere but last. *)
let is_bchar = function
  | '0' .. '9' | 'a' .. 'z' | 'A' .. 'Z' -> true
  | '\'' | '(' | ')' | '+' | '_' | ',' | '-' | '.' | '/' | ':' | '=' | '?' | ' '
    ->
      true
  | _ -> false

let boundary (m : Media_type.t) =
  match (m.type_, Media_type.parameter m "boundary") with
  | "multipart", Some b
    when String.length b >= 1
         && String.length b <= 70
         && String.for_all is_bchar b
         && not (Char.equal b.[String.length b - 1] ' ') ->
      Some b
  | _, (Some _ | None) -> None

(* As a server bounds a request's head. *)
let default_max_head = 16 * 1024

let create ?(max_head = default_max_head) ~boundary pull =
  {
    pull;
    first_boundary = "--" ^ boundary;
    delimiter = "\r\n--" ^ boundary;
    max_head;
    buffer = Buffer.create 0;
    position = 0;
    source_ended = false;
    state = Preamble;
  }

let available t = Buffer.length t.buffer - t.position
let ( let* ) = Result.bind

(* [false] once the source has ended. *)
let pull_more t =
  if t.source_ended then Ok false
  else
    match t.pull () with
    | Error e -> Error (Source e)
    | Ok None ->
        t.source_ended <- true;
        Ok false
    | Ok (Some s) ->
        (* What is read is dropped only once it is most of the buffer, so a
           source pulled a byte at a time costs a copy per half, never one
           per byte. *)
        if t.position > available t then (
          let rest = Buffer.sub t.buffer t.position (available t) in
          Buffer.clear t.buffer;
          Buffer.add_string t.buffer rest;
          t.position <- 0);
        Buffer.add_string t.buffer s;
        Ok true

(* [false] where the body ends before [n] bytes are available. *)
let rec ensure_available t n =
  if available t >= n then Ok true
  else
    let* got = pull_more t in
    if got then ensure_available t n else Ok false

(* Compared in place: content is searched a byte at a time, and a copy at
   each would be the cost. *)
let is_at b i text =
  let n = String.length text in
  i + n <= Buffer.length b
  &&
  let rec matches k =
    k = n || (Char.equal (Buffer.nth b (i + k)) text.[k] && matches (k + 1))
  in
  matches 0

let looking_at t text = is_at t.buffer t.position text

(* [searched] is how much past the position was looked through already. *)
let find ?(searched = 0) t text =
  let rec from i =
    if i + String.length text > Buffer.length t.buffer then None
    else if is_at t.buffer i text then Some i
    else from (i + 1)
  in
  from (t.position + searched)

(* A part's head lines end at CRLF only. *)
let crlf_lines text =
  let rec split from acc =
    let rec find_crlf i =
      if i + 1 >= String.length text then None
      else if Char.equal text.[i] '\r' && Char.equal text.[i + 1] '\n' then
        Some i
      else find_crlf (i + 1)
    in
    match find_crlf from with
    | Some i -> split (i + 2) (String.sub text from (i - from) :: acc)
    | None -> List.rev (String.sub text from (String.length text - from) :: acc)
  in
  if String.equal text "" then [] else split 0 []

let malformed m = Error (Malformed m)

(* The first boundary opens the body, or follows a preamble and a line's
   end. What the search passes is dropped, but for what may yet begin a
   delimiter. *)
let skip_preamble t =
  let* _ = ensure_available t (String.length t.first_boundary) in
  if looking_at t t.first_boundary then (
    t.position <- t.position + String.length t.first_boundary;
    t.state <- After_boundary;
    Ok ())
  else
    let rec search () =
      match find t t.delimiter with
      | Some i ->
          t.position <- i + String.length t.delimiter;
          t.state <- After_boundary;
          Ok ()
      | None ->
          t.position <-
            max t.position
              (Buffer.length t.buffer - String.length t.delimiter + 1);
          let* got = pull_more t in
          if got then search () else malformed "the body has no boundary"
    in
    search ()

(* [--] after the last boundary; otherwise transport padding and CRLF before
   the next part's head. *)
let read_after_boundary t =
  let* _ = ensure_available t 2 in
  if looking_at t "--" then (
    t.position <- t.position + 2;
    t.state <- Finished;
    Ok ())
  else
    let rec skip_padding n =
      if n > t.max_head then Error Head_too_large
      else
        let* _ = ensure_available t 1 in
        if looking_at t " " || looking_at t "\t" then (
          t.position <- t.position + 1;
          skip_padding (n + 1))
        else Ok ()
    in
    let* () = skip_padding 0 in
    let* _ = ensure_available t 2 in
    if looking_at t "\r\n" then (
      t.position <- t.position + 2;
      t.state <- Part_head;
      Ok ())
    else
      malformed "a boundary is followed by something other than its line's end"

(* form-data; name="..."; filename="...". [filename*] is not read (RFC 7578
   §4.2). *)
let content_disposition =
  A.(
    let+ kind = G.token and+ parameters = G.once G.parameters in
    (String.lowercase_ascii kind, parameters))

let part_of_headers headers =
  match Field.find headers "content-disposition" with
  | None -> malformed "a part has no Content-Disposition"
  | Some value -> (
      match G.parse ~what:"a Content-Disposition" content_disposition value with
      | Error m -> malformed m
      | Ok (kind, parameters) -> (
          match (kind, List.assoc_opt "name" parameters) with
          | "form-data", Some name ->
              Ok
                {
                  name;
                  filename = List.assoc_opt "filename" parameters;
                  content_type = content_type_of headers;
                  headers;
                }
          | "form-data", None -> malformed "a part has no name"
          | _, (Some _ | None) -> malformed "a part is not form-data"))

(* A part with no fields has its empty line at once. *)
let read_part_head t =
  let* _ = ensure_available t 2 in
  let* text =
    if looking_at t "\r\n" then (
      t.position <- t.position + 2;
      Ok "")
    else
      let blank_line = "\r\n\r\n" in
      (* Each search starts where the last one could no longer match, so a
         head that arrives a byte at a time is read once. *)
      let rec search ~searched =
        match find ~searched t blank_line with
        | Some i when i - t.position > t.max_head -> Error Head_too_large
        | Some i ->
            let text = Buffer.sub t.buffer t.position (i - t.position) in
            t.position <- i + String.length blank_line;
            Ok text
        | None ->
            if available t > t.max_head then Error Head_too_large
            else
              let searched =
                max 0 (available t - (String.length blank_line - 1))
              in
              let* got = pull_more t in
              if got then search ~searched
              else malformed "a part's head never ends"
      in
      search ~searched:0
  in
  let* headers =
    List.fold_right
      (fun line acc ->
        let* acc = acc in
        match Field.parse line with
        | Ok (name, value) -> Ok ((String.lowercase_ascii name, value) :: acc)
        | Error m -> malformed ("a part's head: " ^ m))
      (crlf_lines text) (Ok [])
  in
  let* part = part_of_headers headers in
  t.state <- Part_content;
  Ok part

(* Hands over what cannot be the start of the delimiter that ends the
   part. *)
let rec read_content t =
  match find t t.delimiter with
  | Some i ->
      let data = Buffer.sub t.buffer t.position (i - t.position) in
      t.position <- i + String.length t.delimiter;
      t.state <- After_boundary;
      Ok (if String.equal data "" then `End else `Data data)
  | None ->
      let deliverable = available t - (String.length t.delimiter - 1) in
      if deliverable > 0 then (
        let data = Buffer.sub t.buffer t.position deliverable in
        t.position <- t.position + deliverable;
        Ok (`Data data))
      else
        let* got = pull_more t in
        if got then read_content t
        else malformed "a part ends before its boundary"

let read t =
  match t.state with
  | Part_content -> read_content t
  | Preamble | After_boundary | Part_head | Finished -> Ok `End

let rec next t =
  match t.state with
  | Preamble ->
      let* () = skip_preamble t in
      next t
  | Part_content ->
      let* _ = read_content t in
      next t
  | After_boundary ->
      let* () = read_after_boundary t in
      next t
  | Part_head -> Result.map Option.some (read_part_head t)
  | Finished -> Ok None

(* A quote and a backslash escaped, and CR and LF, which no quoted-string can
   hold, written %0D and %0A, as the HTML standard has a browser write
   them. *)
let quoted_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '\n' -> Buffer.add_string b "%0A"
      | '\r' -> Buffer.add_string b "%0D"
      | ('"' | '\\') as c ->
          Buffer.add_char b '\\';
          Buffer.add_char b c
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let to_string ~boundary parts =
  let b = Buffer.create 256 in
  List.iter
    (fun (p, content) ->
      Buffer.add_string b ("--" ^ boundary ^ "\r\n");
      Buffer.add_string b
        ("Content-Disposition: form-data; name=" ^ quoted_string p.name);
      Option.iter
        (fun f -> Buffer.add_string b ("; filename=" ^ quoted_string f))
        p.filename;
      Buffer.add_string b "\r\n";
      (* text/plain is what a part with no type is, so it goes unwritten, as
         a browser leaves it; a type that cannot be written is left out
         rather than written wrong. *)
      if not (Media_type.equal p.content_type text_plain) then
        Result.iter
          (fun ct -> Buffer.add_string b ("Content-Type: " ^ ct ^ "\r\n"))
          (Media_type.to_string p.content_type);
      Buffer.add_string b "\r\n";
      Buffer.add_string b content;
      Buffer.add_string b "\r\n")
    parts;
  Buffer.add_string b ("--" ^ boundary ^ "--\r\n");
  Buffer.contents b
