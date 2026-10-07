module R = Eio.Buf_read
module W = Eio.Buf_write
module Sha1 = Digestif.SHA1

type opcode = Continuation | Text | Binary | Close | Ping | Pong

type header = {
  fin : bool;
  opcode : opcode;
  mask : string option;
  length : int;
}

let opcode_of_bits = function
  | 0 -> Ok Continuation
  | 1 -> Ok Text
  | 2 -> Ok Binary
  | 8 -> Ok Close
  | 9 -> Ok Ping
  | 10 -> Ok Pong
  | n -> Error (Printf.sprintf "opcode %d, which no frame has" n)

let opcode_to_bits = function
  | Continuation -> 0
  | Text -> 1
  | Binary -> 2
  | Close -> 8
  | Ping -> 9
  | Pong -> 10

let is_control = function
  | Close | Ping | Pong -> true
  | Continuation | Text | Binary -> false

let ( let* ) = Result.bind

(* Read whole before it is judged, so an error describes the frame as it
   arrived. *)
let read_header r =
  let b0 = Char.code (R.any_char r) in
  let b1 = Char.code (R.any_char r) in
  let length =
    match b1 land 0x7f with
    | 126 -> Ok (R.BE.uint16 r)
    | 127 ->
        let n = R.BE.uint64 r in
        if Int64.compare n 0L < 0 || Int64.compare n (Int64.of_int max_int) > 0
        then Error "a 64-bit length with its high bit set"
        else Ok (Int64.to_int n)
    | n -> Ok n
  in
  let mask = if b1 land 0x80 <> 0 then Some (R.take 4 r) else None in
  let fin = b0 land 0x80 <> 0 in
  let* length = length in
  let* opcode = opcode_of_bits (b0 land 0x0f) in
  if b0 land 0x70 <> 0 then Error "a reserved bit set, with no extension agreed"
  else if is_control opcode && not fin then Error "a fragmented control frame"
  else if is_control opcode && length > 125 then
    Error "a control frame longer than 125 bytes"
  else Ok { fin; opcode; mask; length }

(* [at] is the piece's offset in the payload, which picks the mask byte
   (§5.3). *)
let apply_mask m ~at s =
  String.mapi
    (fun i c -> Char.chr (Char.code c lxor Char.code m.[(at + i) land 3]))
    s

let read_payload r h buf =
  let rec go at =
    if at < h.length then (
      R.ensure r 1;
      let n = min (h.length - at) (R.buffered_bytes r) in
      let piece = R.take n r in
      Buffer.add_string buf
        (match h.mask with None -> piece | Some m -> apply_mask m ~at piece);
      go (at + n))
  in
  go 0

(* Written and flushed a piece at a time, so the send limit bounds each. *)
let write_piece_bytes = 16_384

let write w ?mask ~fin opcode payload ~flush =
  let length = String.length payload in
  let masking = match mask with Some _ -> 0x80 | None -> 0 in
  W.uint8 w ((if fin then 0x80 else 0) lor opcode_to_bits opcode);
  if length < 126 then W.uint8 w (masking lor length)
  else if length < 65536 then (
    W.uint8 w (masking lor 126);
    W.BE.uint16 w length)
  else (
    W.uint8 w (masking lor 127);
    W.BE.uint64 w (Int64.of_int length));
  Option.iter (W.string w) mask;
  let rec go at =
    let n = min write_piece_bytes (length - at) in
    let s = String.sub payload at n in
    W.string w (match mask with None -> s | Some m -> apply_mask m ~at s);
    match flush () with
    | Error _ as e -> e
    | Ok () -> if at + n >= length then Ok () else go (at + n)
  in
  go 0

(* §1.3: SHA-1 of the key and the protocol's fixed GUID. *)
let accept_key key =
  Base64.encode_string
    (Sha1.to_raw_string
       (Sha1.digest_string (key ^ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
