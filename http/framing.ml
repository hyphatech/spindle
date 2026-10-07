type t = No_body | Fixed of int | Chunked | Until_close

let is_digits s =
  String.length s > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) s

(* RFC 9112 §6.3 accepts a list of equal lengths, "5, 5", as one length.
   Past eighteen digits it is no length anybody means, and no int. *)
let content_length values =
  match List.concat_map Field.elements values with
  | [] -> Error "an empty Content-Length"
  | first :: rest ->
      if not (is_digits first && String.length first <= 18) then
        Error (Printf.sprintf "Content-Length %S" first)
      else if not (List.for_all (String.equal first) rest) then
        Error "Content-Length given twice, differently"
      else Ok (int_of_string first)

let of_content_length values =
  Result.map (function 0 -> No_body | n -> Fixed n) (content_length values)

(* Read as a list, so an empty element is nothing (RFC 9110 §5.6.1).
   Chunked twice is refused: no sender may write it (RFC 9112 §6.1), and two
   readers could unwrap it to different depths. *)
let transfer_codings values =
  let codings =
    List.concat_map Field.elements values |> List.map String.lowercase_ascii
  in
  if List.length (List.filter (String.equal "chunked") codings) > 1 then `Twice
  else
    match List.rev codings with
    | [ "chunked" ] -> `Chunked
    | "chunked" :: _ -> `Under_chunked
    | _ -> `Not_chunked

let of_request (head : Head.Request.t) =
  let bad_request detail = Error (`Bad_request, detail) in
  let all = Field.all head.headers in
  match (all "transfer-encoding", all "content-length") with
  | [], [] -> Ok No_body
  | _ :: _, _ :: _ -> bad_request "both Transfer-Encoding and Content-Length"
  | [], lengths ->
      Result.map_error (fun d -> (`Bad_request, d)) (of_content_length lengths)
  | values, [] -> (
      match transfer_codings values with
      | `Chunked -> Ok Chunked
      | `Under_chunked ->
          Error (`Not_implemented, "a transfer coding under chunked")
      | `Twice -> bad_request "chunked applied more than once"
      | `Not_chunked ->
          bad_request "a Transfer-Encoding that does not end in chunked")

(* RFC 9112 §6.3, in its order: no content whatever the fields say, then a
   tunnel, then the fields. *)
let of_response ~request_meth (head : Head.Response.t) =
  let code = Status.to_int head.status in
  let is_connect =
    match request_meth with `Other "CONNECT" -> true | _ -> false
  in
  let all = Field.all head.headers in
  if Meth.equal request_meth `HEAD || code < 200 || code = 204 || code = 304
  then Ok No_body
  else if is_connect && code < 300 then Ok No_body
  else
    match (all "transfer-encoding", all "content-length") with
    | [], [] -> Ok Until_close
    (* A response that can be read two ways. *)
    | _ :: _, _ :: _ -> Error "both Transfer-Encoding and Content-Length"
    | [], lengths -> of_content_length lengths
    | values, [] -> (
        match transfer_codings values with
        | `Chunked -> Ok Chunked
        | `Twice -> Error "chunked applied more than once"
        (* Read to the close, this would be the coding's bytes, which nothing
           here decodes (§7.4). *)
        | `Under_chunked | `Not_chunked ->
            Error "a transfer coding this reader does not decode")

type state = Size_line | In_chunk of int | Done | Failed of string

(* [extensions] counts the bytes after ";" on chunk-size lines, which are
   never delivered but count against the body's limit. *)
type reader = {
  framing : t;
  ic : Eio.Buf_read.t;
  max_trailer : int;
  mutable consumed : int;
  mutable extensions : int;
  mutable state : state;
}

let reader framing ic ~max_trailer =
  let state =
    match framing with
    | No_body -> Done
    | Fixed _ | Chunked | Until_close -> Size_line
  in
  { framing; ic; max_trailer; consumed = 0; extensions = 0; state }

let bytes_spent r = r.consumed + r.extensions

(* The largest piece read at once. *)
let piece_bytes = 65_536

exception Broken of string

(* [Failure] is [Buf_read]'s parser refusing a byte it expected; anything
   else the flow raises, a TLS alert say, is the flow failing under the
   body. *)
let read_or_break r f =
  match f r.ic with
  | v -> v
  | exception End_of_file -> raise (Broken "the body ended early")
  | exception Eio.Buf_read.Buffer_limit_exceeded ->
      raise (Broken "a chunk-size line longer than the buffer")
  | exception Failure _ -> raise (Broken "a chunk not followed by CRLF")
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex -> raise (Broken (Printexc.to_string ex))

(* CRLF only: a reader that took a bare LF here would find a different body
   in the same bytes. *)
let read_crlf_line r =
  match read_or_break r Field.line with
  | Ok l -> l
  | Error `Bare_lf -> raise (Broken "a line in a chunked body ending in LF")
  | Error `Bare_cr -> raise (Broken "a bare CR in a chunked body")
  | Error `Too_long -> raise (Broken "a line in a chunked body past the buffer")
  | Error `Closed -> raise (Broken "the body ended early")

(* Up to [n] of what is buffered, waiting for at least one byte. *)
let take_buffered r n =
  read_or_break r (fun ic ->
      Eio.Buf_read.ensure ic 1;
      Eio.Buf_read.take (min n (Eio.Buf_read.buffered_bytes ic)) ic)

let is_hex = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

(* chunk-size [BWS ";" chunk-ext]. Fifteen hex digits is past any int a body
   could be. *)
let chunk_size line =
  let size =
    match String.index_opt line ';' with
    | Some i ->
        let s = String.sub line 0 i in
        let rec trimmed_length n =
          if n > 0 && (s.[n - 1] = ' ' || s.[n - 1] = '\t') then
            trimmed_length (n - 1)
          else n
        in
        String.sub s 0 (trimmed_length (String.length s))
    | None -> line
  in
  if
    String.length size > 0
    && String.length size <= 15
    && String.for_all is_hex size
  then int_of_string ("0x" ^ size)
  else raise (Broken (Printf.sprintf "a chunk size %S" size))

(* Held to the head's field grammar: a line that is not a field is where a
   reader that skips it and one that does not part ways. *)
let rec skip_trailer r ~seen =
  match read_crlf_line r with
  | "" -> ()
  | line -> (
      let seen = seen + String.length line in
      if seen > r.max_trailer then raise (Broken "a trailer past its limit")
      else
        match Field.parse line with
        | Ok _ -> skip_trailer r ~seen
        | Error detail -> raise (Broken ("a trailer line: " ^ detail)))

(* At most [n] bytes; [None] at the end. *)
let rec next r n =
  match (r.framing, r.state) with
  | _, Done -> None
  | _, Failed m -> raise (Broken m)
  | No_body, _ -> None
  | Fixed total, _ ->
      let left = total - r.consumed in
      if left = 0 then (
        r.state <- Done;
        None)
      else
        let s = take_buffered r (min n left) in
        r.consumed <- r.consumed + String.length s;
        Some s
  | Chunked, Size_line -> (
      let size_line = read_crlf_line r in
      (match String.index_opt size_line ';' with
      | Some i -> r.extensions <- r.extensions + String.length size_line - i
      | None -> ());
      match chunk_size size_line with
      | 0 ->
          skip_trailer r ~seen:0;
          r.state <- Done;
          None
      | size ->
          r.state <- In_chunk size;
          next r n)
  | Until_close, _ ->
      (* The end of input is this body's end, not a body cut short. *)
      let at_end ic =
        match Eio.Buf_read.ensure ic 1 with
        | () -> false
        | exception End_of_file -> true
      in
      if read_or_break r at_end then (
        r.state <- Done;
        None)
      else
        let s = take_buffered r n in
        r.consumed <- r.consumed + String.length s;
        Some s
  | Chunked, In_chunk left ->
      let s = take_buffered r (min n left) in
      let left = left - String.length s in
      r.consumed <- r.consumed + String.length s;
      if left = 0 then (
        read_or_break r (Eio.Buf_read.string "\r\n");
        r.state <- Size_line)
      else r.state <- In_chunk left;
      Some s

let fail_on_break r f =
  match f () with
  | v -> v
  | exception Broken m ->
      r.state <- Failed m;
      raise (Broken m)

let read r ~max ~reserve =
  (* Pieces rather than a buffer sized ahead: most bodies arrive as one
     piece, which is then the body. *)
  let rec collect pieces =
    match fail_on_break r (fun () -> next r piece_bytes) with
    | None -> (
        match pieces with
        | [ s ] -> Ok s
        | _ -> Ok (String.concat "" (List.rev pieces)))
    | Some s ->
        if bytes_spent r > max then Error `Too_large
        else if not (reserve (String.length s)) then Error `Busy
        else collect (s :: pieces)
  in
  (* Reserved as bytes arrive, not as a length declares them. *)
  match r.framing with
  | No_body -> Ok ""
  | Fixed n when n > max -> Error `Too_large
  | Fixed _ | Chunked | Until_close -> (
      try collect [] with Broken m -> Error (`Broken m))

let read_some r ~max ~reserve =
  match r.framing with
  | Fixed n when n > max -> Error `Too_large
  | No_body | Fixed _ | Chunked | Until_close -> (
      match fail_on_break r (fun () -> next r piece_bytes) with
      | None -> Ok `End
      | Some s ->
          if bytes_spent r > max then Error `Too_large
          else if not (reserve (String.length s)) then Error `Busy
          else Ok (`Data s)
      | exception Broken m -> Error (`Broken m))

let discard r ~limit =
  let rec discard_up_to left =
    if left < 0 then false
    else
      let before = bytes_spent r in
      match fail_on_break r (fun () -> next r (left + 1)) with
      | None -> true
      | Some _ -> discard_up_to (left - (bytes_spent r - before))
  in
  match (r.framing, r.state) with
  | _, Done -> true
  | _, Failed _ -> false
  | Fixed total, _ when total - r.consumed > limit -> false
  | (No_body | Fixed _ | Chunked | Until_close), _ -> (
      try discard_up_to limit with Broken _ -> false)
