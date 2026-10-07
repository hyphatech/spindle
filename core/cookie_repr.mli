(** A cookie as the framework holds it: writing [Set-Cookie], reading [Cookie],
    encoding a value. What {!Cookie} is, underneath; each value {!Cookie}
    exports is documented there. *)

type same_site = Strict | Lax

type t
(** A cookie to set. *)

type 'a named
(** A cookie declared once, its name and its codec, read and written by it. *)

val named : string -> 'a Codec.t -> 'a named
(** As {!Cookie.named}. Raises [Invalid_argument] for a name no cookie can
    carry. *)

val signed : Key.ring -> ?max_age:int -> string -> 'a Codec.t -> 'a named
(** As {!Cookie.signed}. *)

val encrypted : Key.ring -> ?max_age:int -> string -> 'a Codec.t -> 'a named
(** As {!Cookie.encrypted}. *)

module Named : sig
  val name : 'a named -> string
  val codec : 'a named -> 'a Codec.t
  val sealed : 'a named -> bool

  val unseal : 'a named -> now:int -> string -> string option
  (** The value a request carried, if its signature, seal and age hold at [now];
      the value itself for a plain cookie. *)
end

val make :
  ?path:string ->
  ?max_age:int ->
  ?http_only:bool ->
  ?same_site:same_site ->
  'a named ->
  'a ->
  t
(** As {!Cookie.make}. Raises [Invalid_argument] for a value its codec prints
    that no cookie can hold, or a path. *)

val clear : ?path:string -> 'a named -> t
(** As {!Cookie.clear}. Raises as {!make} does, for a path. *)

val encode : string -> string
(** Base64url with no padding, every character of which a cookie holds. *)

val decode : string -> string option
(** What {!encode} wrote, and only that spelling of it. *)

val to_header : secure:bool -> now:int -> t -> string
(** The [Set-Cookie] value, a sealed one sealed at [now]; [SameSite] always
    written, [Secure] where [secure]. *)

val parse : string -> (string * string) list
(** A [Cookie] value's pairs, in order, each trimmed; one with no name or no [=]
    passed over. *)
