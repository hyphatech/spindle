(** A message written: a start line and its fields, then a body's chunks, onto
    an [Eio.Buf_write.t]. Nothing here flushes; when the bytes leave is the
    caller's to decide.

    A head is checked whole before any of it is written, so a refused one leaves
    nothing on the connection. *)

val response_head :
  Eio.Buf_write.t ->
  Status.t ->
  (string * string) list ->
  (unit, [ `Field of string | `Status ]) result
(** [HTTP/1.1], the status and its reason, the fields and the empty line.
    [`Status] for a status outside 100 to 599 (RFC 9110 §15), which a reader
    refuses, and [`Field name] for the first field that is not
    {!Field.is_writable}. The space after the code is written even when the
    reason is empty, as RFC 9112 asks. *)

val request_head :
  Eio.Buf_write.t ->
  Meth.t ->
  target:string ->
  (string * string) list ->
  (unit, [ `Field of string | `Target ]) result
(** The request line for [HTTP/1.1], the fields and the empty line. [`Target]
    for a target that is empty or holds anything but visible ASCII, which would
    end the line somewhere else; a method that is not a token is a [`Target]
    too, for the same reason. *)

val continue : Eio.Buf_write.t -> unit
(** [100 Continue]: a client that asked is told to send its body. *)

val chunk : Eio.Buf_write.t -> string -> unit
(** One chunk of a chunked body, and nothing for an empty string: an empty chunk
    is the last one, and ends the body. *)

val last_chunk : Eio.Buf_write.t -> unit
(** The chunk that ends a chunked body, with no trailer. *)

val date : int -> string
(** An instant, given in milliseconds since the epoch, as RFC 9110 §5.6.7's
    IMF-fixdate -- [Sun, 06 Nov 1994 08:49:37 GMT] -- which is the one form of
    date a sender may write. One outside the years 0000 to 9999 is written as
    the nearest instant in them, since the form has four digits for a year. *)
