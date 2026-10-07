(** Cookies: the ones a response sets, and reading the ones a request carries.

    A cookie is declared once, by its name and the codec its value is read and
    written by, and used both ways:

    {[
    let visits = Spindle.Cookie.named "visits" Spindle.Codec.int

    let+ n = Spindle.Cookie.optional visits in ...
    set_cookie (Spindle.Cookie.make visits 3)
    ]}

    A cookie is [HttpOnly] and [SameSite=Lax] unless it says otherwise, and
    whether it is [Secure] is not the handler's to decide: the response is
    written with [Secure] on every host but a loopback one (see
    {!Request.secure}). *)

type same_site = Cookie_repr.same_site = Strict | Lax

type 'a named = 'a Cookie_repr.named
(** A cookie of the application's: its name, and the codec its value is read and
    written by. *)

val named : string -> 'a Codec.t -> 'a named
(** [named name codec]. Raises [Invalid_argument] for a name that is not a
    token: a cookie's name is a constant written in source. *)

(** {1 Cookies a browser cannot forge}

    {[
    let prefs =
      Spindle.Cookie.encrypted keys ~max_age:(30 * 86400) "prefs" prefs_codec

    let who = Spindle.Cookie.signed keys "who" Spindle.Codec.string
    ]}

    Both are {!type-named}, read and set as any declared cookie is. Each value
    is stamped with the second it was made, from the application's [now] as the
    answer is written, and bound to the cookie's name, so it cannot be moved to
    another cookie.
    {b One that fails its signature, its seal or its age is absent} --
    [Cookie.optional] answers [None], and the failure is a [debug] line naming
    the cookie -- because a browser holding one from a retired key or an old
    visit has done nothing wrong. [max_age] is the server's as well as the
    browser's: one made longer ago is refused whatever the browser was told,
    since a copied cookie replays for ever; it is also the most {!make} writes
    as its [Max-Age]. *)

val signed : Key.ring -> ?max_age:int -> string -> 'a Codec.t -> 'a named
(** The value readable by the browser, and an HMAC-SHA256 over the name, the
    stamp and the value beside it ({!Key.sign}), compared in constant time.
    Raises as {!val-named} does. *)

val encrypted : Key.ring -> ?max_age:int -> string -> 'a Codec.t -> 'a named
(** The value and its stamp sealed with AES-256-GCM ({!Key.seal}), the name
    bound to them: a browser can read nothing of it. Raises as {!val-named}
    does. *)

(** What a declared cookie is, for whatever reads one. *)
module Named : sig
  val name : 'a named -> string
  val codec : 'a named -> 'a Codec.t

  val sealed : 'a named -> bool
  (** Whether it is {!signed} or {!encrypted}. *)

  val unseal : 'a named -> now:int -> string -> string option
  (** The value a request carried for it, as its codec reads it: the value
      itself for a plain cookie, and for a sealed one what it sealed, if its
      signature, its seal and its age hold at [now]. *)
end

type t = Cookie_repr.t
(** A cookie to set. *)

val make :
  ?path:string ->
  ?max_age:int ->
  ?http_only:bool ->
  ?same_site:same_site ->
  'a named ->
  'a ->
  t
(** [make cookie value]: the value printed by the cookie's codec. [path]
    defaults to ["/"]; without [max_age] the cookie lasts as long as the
    browser's session.

    Raises [Invalid_argument] for a printed value or a path RFC 6265 does not
    allow -- a space, a quote, a comma, a semicolon, a backslash or a control
    character, any of which could end the cookie early or write an attribute of
    its own. A token the application mints, a number, a word of an enum: none
    can. Text that arrived at run time is declared with the [encoded] codec,
    which writes any string as one a cookie can hold ([Spindle.Cookie.encoded]).
*)

val clear : ?path:string -> 'a named -> t
(** [clear cookie] removes the cookie at [path]: an empty value with no
    lifetime, which is the only way to take one out of a browser. Raises as
    {!make} does for a path. *)
