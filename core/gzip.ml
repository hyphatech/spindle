(* gzip (RFC 1952) in which every write can be decoded at once. decompress's
   LZ77 has no flush, so each write is an LZ77 pass of its own, its symbols a
   block of the one deflate stream, then an empty stored block, which aligns
   the output to a byte as zlib's Z_SYNC_FLUSH does. A write cannot match
   against earlier writes. *)

module Def = De.Def
module Lz77 = De.Lz77
module Q = De.Queue

type t = {
  level : int;
  queue : Q.t;
  window : Lz77.window;
  encoder : Def.encoder;
  output : De.bigstring;
  out : Buffer.t;
  mutable crc : Checkseum.Crc32.t;
  mutable size : int;
  mutable started : bool;
}

let create ~level =
  let queue = Q.create 4096 in
  let encoder = Def.encoder `Manual ~q:queue in
  let output = De.bigstring_create 16384 in
  Def.dst encoder output 0 (De.bigstring_length output);
  {
    level;
    queue;
    window = Lz77.make_window ~bits:15;
    encoder;
    output;
    out = Buffer.create 256;
    crc = Checkseum.Crc32.default;
    size = 0;
    started = false;
  }

(* ID1 ID2, deflate, no flags, no time, no extra flags, an unknown system. *)
let header = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff"

let move_output t =
  let len = De.bigstring_length t.output - Def.dst_rem t.encoder in
  Buffer.add_string t.out
    (String.init len (fun i -> Bigarray.Array1.get t.output i));
  Def.dst t.encoder t.output 0 (De.bigstring_length t.output)

let rec encode_through t = function
  | `Partial ->
      move_output t;
      encode_through t (Def.encode t.encoder `Await)
  | (`Ok | `Block) as v -> v

let take_output t =
  move_output t;
  let s = Buffer.contents t.out in
  Buffer.clear t.out;
  s

let empty_stored_block = { Def.kind = Def.Flat; last = false }

let write t s =
  if not t.started then (
    Buffer.add_string t.out header;
    t.started <- true);
  t.crc <- Checkseum.Crc32.digest_string s 0 (String.length s) t.crc;
  t.size <- t.size + String.length s;
  let st = Lz77.state ~level:t.level ~q:t.queue ~w:t.window (`String s) in
  let block () =
    Def.block_of_frequencies ~last:false ~literals:(Lz77.literals st)
      ~distances:(Lz77.distances st)
  in
  (* [`Block] with symbols queued needs another block; with none, it ends
     this write, and the empty stored block follows. *)
  let rec encoded ~ended = function
    | `Ok -> if ended then () else compress ()
    | `Block when Q.is_empty t.queue && ended -> (
        match
          encode_through t (Def.encode t.encoder (`Block empty_stored_block))
        with
        | `Ok | `Block -> ())
    | `Block ->
        encoded ~ended
          (encode_through t (Def.encode t.encoder (`Block (block ()))))
  and compress () =
    match Lz77.compress st with
    | `Flush ->
        encoded ~ended:false
          (encode_through t (Def.encode t.encoder (`Block (block ()))))
    | `End | `Await ->
        encoded ~ended:true
          (encode_through t (Def.encode t.encoder (`Block (block ()))))
  in
  compress ();
  take_output t

let le32 n = String.init 4 (fun i -> Char.chr ((n lsr (8 * i)) land 0xff))

(* The last block, empty, and the trailer: the CRC-32 and the length. *)
let finish t =
  let prefix = if t.started then "" else header in
  t.started <- true;
  Q.push_exn t.queue Q.eob;
  (match
     encode_through t
       (Def.encode t.encoder (`Block { Def.kind = Def.Fixed; last = true }))
   with
  | `Ok | `Block -> ());
  let body = take_output t in
  prefix ^ body ^ le32 (Optint.to_int t.crc) ^ le32 (t.size land 0xffffffff)

let string ~level s =
  let t = create ~level in
  let body = write t s in
  body ^ finish t
