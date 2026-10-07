(** A WebSocket's frames, as RFC 6455 §5 spells them: read from a buffer and
    written to one, and nothing about what a conversation of them means.

    A payload is read in pieces, however large it is, so the reader's buffer
    never has to hold a whole frame: a server's is the connection's own, sized
    for a request head. *)

type opcode = Continuation | Text | Binary | Close | Ping | Pong

type header = {
  fin : bool;
  opcode : opcode;
  mask : string option;  (** the four bytes, when the frame is masked *)
  length : int;
}

val read_header : Eio.Buf_read.t -> (header, string) result
(** The next frame's header, or what is wrong with it: a reserved bit set with
    no extension agreed (§5.2), an opcode no frame has, a control frame that is
    fragmented or longer than 125 bytes (§5.5), or a 64-bit length with its high
    bit set. [End_of_file] where the connection ends, as any read. *)

val read_payload : Eio.Buf_read.t -> header -> Buffer.t -> unit
(** Appends the frame's payload, unmasked, to the buffer. *)

val write :
  Eio.Buf_write.t ->
  ?mask:string ->
  fin:bool ->
  opcode ->
  string ->
  flush:(unit -> (unit, 'e) result) ->
  (unit, 'e) result
(** Writes one frame, in the fewest bytes its length allows (§5.2), masked with
    [mask] when given, and calls [flush] after every sixteen KiB of it: a peer
    that takes nothing stops the write within one piece, and one still reading
    slowly is never cut off for being slow. *)

val accept_key : string -> string
(** [Sec-WebSocket-Accept] for a [Sec-WebSocket-Key] (§4.2.2). *)
