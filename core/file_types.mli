(** A file's media type by its name, and the precompressed siblings a build
    writes beside it, shared by {!Static} and {!Files}. *)

val content_type : types:(string * string) list -> string -> string
(** The type of a file by its extension, compared without case, [types] before
    the built-in table, and [application/octet-stream] for one neither knows. *)

val extension : string -> string
(** The suffix a coding's sibling file carries, [.br] for [br]; empty for a
    coding with none. *)

val siblings : (string * string) list
(** Each content coding and the suffix its sibling file carries, most preferred
    first. *)

val coding : Request.t -> available:string list -> string option
(** The coding to answer in, of those [available] that have a sibling, as the
    request's [Accept-Encoding] weighs them, {!siblings}' order breaking a tie;
    [None] for the file as it is. *)
