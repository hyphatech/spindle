(** gzip (RFC 1952) written a piece at a time: deflate from [decompress] and the
    CRC-32 its trailer carries. *)

type t
(** One stream being written. *)

val create : level:int -> t
(** A stream at deflate's [level], 0 to 9. *)

val write : t -> string -> string
(** [write t s]: what [s] adds to the stream, ended at a block boundary so a
    client can read it as it arrives; the first piece carries the header. *)

val finish : t -> string
(** The rest of the stream and its trailer; the stream takes no more. *)

val string : level:int -> string -> string
(** A whole body, compressed in one piece. *)
