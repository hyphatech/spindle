(** A cookie as the framework holds it: writing [Set-Cookie], reading [Cookie],
    encoding a value. What {!Cookie} is, underneath; each value {!Cookie}
    exports is documented there. *)

type same_site = Strict | Lax

type t
(** A cookie to set. *)

type 'a named
(** A cookie declared once, its name and its description, read and written by
    it. *)

val named : string -> 'a Wiretype.t -> 'a named
(** As {!Cookie.named}. Raises [Invalid_argument] for a name no cookie can
    carry. *)

val whole_seconds : Mtime.Span.t -> int
(** The span in whole seconds, rounded up: a cookie's [Max-Age] is never shorter
    than what it was declared with. *)

val signed : max_age:Mtime.Span.t -> string -> 'a Wiretype.t -> 'a named
(** As {!Cookie.signed}. *)

val encrypted : max_age:Mtime.Span.t -> string -> 'a Wiretype.t -> 'a named
(** As {!Cookie.encrypted}. *)

module Named : sig
  val name : 'a named -> string
  val description : 'a named -> 'a Wiretype.t
  val sealed : 'a named -> bool

  val unseal :
    'a named -> keys:Key_repr.ring -> now:Ptime.t -> string -> string option
  (** The value a request carried, if its signature, seal and age hold at [now]
      under [keys]; for a plain cookie its value decoded, if it is one
      ({!unescape}). *)
end

val make :
  ?path:string ->
  ?max_age_s:int ->
  ?http_only:bool ->
  ?same_site:same_site ->
  'a named ->
  'a ->
  t
(** As {!Cookie.make}. Raises [Invalid_argument] for a path no cookie can hold.
*)

val clear : ?path:string -> 'a named -> t
(** As {!Cookie.clear}. Raises as {!make} does, for a path. *)

val unescape : string -> string option
(** A plain cookie's value as its description wrote it: every escape decoded, in
    either case, and [None] for a [%] not followed by two hex digits. *)

val encode : string -> string
(** Base64url with no padding, every character of which a cookie holds. *)

val decode : string -> string option
(** What {!encode} wrote, and only that spelling of it. *)

val to_header :
  secure:bool ->
  now:Ptime.t ->
  keys:Key_repr.ring option ->
  t ->
  (string, string) result
(** The [Set-Cookie] value, a sealed one sealed at [now] under [keys];
    [SameSite] always written, [Secure] where [secure]. [Error], saying why, for
    a sealed one and no [keys]. *)

val parse : string -> (string * string) list
(** A [Cookie] value's pairs, in order, each trimmed; one with no name or no [=]
    passed over. *)
