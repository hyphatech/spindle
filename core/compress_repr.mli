(** What {!Compress} is, underneath: shared with the server, which decides
    whether an answer is compressed. *)

type policy = {
  min_bytes : int;  (** an answer shorter than this is sent as it is *)
  level : int;  (** deflate's level, 0 to 9 *)
  types : string list;
      (** the media types compressed: [type/subtype], [type/*] or
          [type/*+suffix], compared without case *)
}

type t = policy option
(** [None] compresses nothing. *)

val compressible : policy -> string option -> bool
(** Whether an answer of this [Content-Type] is one [policy] compresses. *)

val gzip_tag : Spindle_http.Etag.t -> Spindle_http.Etag.t
(** The tag of a representation gzipped as it is answered: its own, marked
    [-gzip], since a tag names one representation. *)

val unmarked : Spindle_http.Etag.t -> Spindle_http.Etag.t option
(** The tag a {!gzip_tag} was made from; [None] for one that is not marked. *)
