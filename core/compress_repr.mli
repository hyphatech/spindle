(** What {!Compress} is, underneath: shared with the server, which decides
    whether an answer is compressed. *)

type t = {
  min_bytes : int;  (** an answer shorter than this is sent as it is *)
  level : int;  (** deflate's level, 0 to 9 *)
  types : string list;
      (** the media types compressed: [type/subtype], [type/*] or
          [type/*+suffix], compared without case *)
}

val never : unit Meta.key
(** A route's mark that its answers are never compressed. *)

val compressible : t -> string option -> bool
(** Whether an answer of this [Content-Type] is one [t] compresses. *)
