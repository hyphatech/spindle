(* Reading follows the HTML standard's "interpreting an event stream" step by
   step. *)

(* A line ends at CRLF, LF or a lone CR: split at LF alone, a CR could begin
   a line a reader takes as a field. *)
let split_lines s =
  let b = Buffer.create (String.length s) in
  String.iteri
    (fun i c ->
      match c with
      | '\r' when i + 1 < String.length s && Char.equal s.[i + 1] '\n' -> ()
      | '\r' -> Buffer.add_char b '\n'
      | c -> Buffer.add_char b c)
    s;
  String.split_on_char '\n' (Buffer.contents b)

(* Data holding a line break is several [data:] lines. *)
let field_lines name s =
  String.concat "" (List.map (fun l -> name ^ l ^ "\n") (split_lines s))

let has_line_break s =
  String.exists (fun c -> Char.equal c '\n' || Char.equal c '\r') s

let ( let* ) = Result.bind

let event ?name ?id data =
  let* name_line =
    match name with
    | None -> Ok ""
    | Some n when has_line_break n ->
        Error (Printf.sprintf "the event name %S holds a line break" n)
    | Some n -> Ok ("event: " ^ n ^ "\n")
  in
  let* id_line =
    match id with
    | None -> Ok ""
    | Some id when has_line_break id || String.contains id '\000' ->
        Error (Printf.sprintf "the event id %S holds a line break or a NUL" id)
    | Some id -> Ok ("id: " ^ id ^ "\n")
  in
  Ok (name_line ^ id_line ^ field_lines "data: " data ^ "\n")

let retry ms =
  if ms < 0 then
    Error (Printf.sprintf "a retry of %d ms, which no reader takes" ms)
  else Ok (Printf.sprintf "retry: %d\n\n" ms)

let comment s = field_lines ": " s ^ "\n"

type event = {
  name : string;
  data : string;
  id : string option;
  retry : int option;
}

type reader = {
  max_event : int;
  line : Buffer.t;  (** the line not yet ended *)
  data : Buffer.t;
  mutable event_type : string;
  mutable id_buffer : string;
  mutable last_id : string;
  mutable retry : int option;
  mutable after_cr : bool;
      (** the last piece ended at a CR, whose LF may follow *)
  mutable past_bom : bool;  (** past where a byte-order mark may be *)
  mutable bom_prefix : string;  (** the first bytes, while they may be one *)
}

(* A mebibyte, as a body's and a WebSocket message's default limits are. *)
let default_max_event = 1 lsl 20

let reader ?(last_id = "") ?(max_event = default_max_event) () =
  {
    max_event;
    line = Buffer.create 128;
    data = Buffer.create 256;
    event_type = "";
    id_buffer = last_id;
    last_id;
    retry = None;
    after_cr = false;
    past_bom = false;
    bom_prefix = "";
  }

let non_empty = function "" -> None | s -> Some s

(* A blank line dispatches the event, if it has data. *)
let dispatch r =
  r.last_id <- r.id_buffer;
  let data = Buffer.contents r.data in
  Buffer.clear r.data;
  let event_type = r.event_type in
  r.event_type <- "";
  if String.equal data "" then None
  else
    let data =
      if String.ends_with ~suffix:"\n" data then
        String.sub data 0 (String.length data - 1)
      else data
    in
    Some
      {
        name = (if String.equal event_type "" then "message" else event_type);
        data;
        id = non_empty r.last_id;
        retry = r.retry;
      }

let process_line r line =
  if String.equal line "" then dispatch r
  else if Char.equal line.[0] ':' then None
  else
    let name, value =
      match String.index_opt line ':' with
      | None -> (line, "")
      | Some i ->
          let v = String.sub line (i + 1) (String.length line - i - 1) in
          ( String.sub line 0 i,
            if String.starts_with ~prefix:" " v then
              String.sub v 1 (String.length v - 1)
            else v )
    in
    (match name with
    | "event" -> r.event_type <- value
    | "data" ->
        Buffer.add_string r.data value;
        Buffer.add_char r.data '\n'
    | "id" -> if not (String.contains value '\000') then r.id_buffer <- value
    | "retry" ->
        if
          String.length value > 0
          && String.for_all (function '0' .. '9' -> true | _ -> false) value
        then r.retry <- int_of_string_opt value
    | _ -> ());
    None

let bom = "\xef\xbb\xbf"

(* A byte-order mark may arrive a byte at a time. *)
let strip_bom r piece =
  if r.past_bom then piece
  else
    let start = r.bom_prefix ^ piece in
    if String.length start < 3 && String.starts_with ~prefix:start bom then (
      r.bom_prefix <- start;
      "")
    else (
      r.past_bom <- true;
      r.bom_prefix <- "";
      if String.starts_with ~prefix:bom start then
        String.sub start 3 (String.length start - 3)
      else start)

(* What is held between events -- the line not yet ended and the data not
   yet dispatched -- is bounded, or a peer that never ends a line is a
   buffer that grows for as long as it keeps sending. *)
let feed r piece =
  let piece = strip_bom r piece in
  let events = ref [] in
  let end_line () =
    let line = Buffer.contents r.line in
    Buffer.clear r.line;
    Option.iter (fun e -> events := e :: !events) (process_line r line)
  in
  String.iter
    (fun c ->
      match c with
      | '\n' when r.after_cr -> r.after_cr <- false
      | '\n' -> end_line ()
      | '\r' ->
          r.after_cr <- true;
          end_line ()
      | c ->
          r.after_cr <- false;
          Buffer.add_char r.line c)
    piece;
  if Buffer.length r.line + Buffer.length r.data > r.max_event then
    Error (Printf.sprintf "an event longer than %d bytes" r.max_event)
  else Ok (List.rev !events)

let last_id r = non_empty r.last_id
