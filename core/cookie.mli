(** Cookies: the ones a response sets, and reading the ones a request carries.

    A cookie is declared once, by its name and the description its value is read
    and written by, and used both ways:

    {[
    let visits = Spindle.Cookie.named "visits" Wiretype.int

    let+ n = Spindle.Cookie.optional visits in ...
    set_cookie (Spindle.Cookie.make visits 3)
    ]}

    A cookie is [HttpOnly] and [SameSite=Lax] unless it says otherwise, and
    whether it is [Secure] is not the handler's to decide: the response is
    written with [Secure] on every host but a loopback one (see
    {!Request.secure}). *)

type same_site = Cookie_repr.same_site = Strict | Lax

type 'a named = 'a Cookie_repr.named
(** A cookie of the application's: its name, and the description its value is
    read and written by. *)

val named : string -> 'a Wiretype.t -> 'a named
(** [named name description]. Raises [Invalid_argument] for a name that is not a
    token: a cookie's name is a constant written in source. *)

(** {1 Cookies a browser cannot forge}

    {[
    let prefs =
      Spindle.Cookie.encrypted
        ~max_age:Mtime.Span.(30 * day)
        "prefs" prefs_description

    let who =
      Spindle.Cookie.signed ~max_age:Mtime.Span.(8 * hour) "who" Wiretype.string
    ]}

    Both are {!type-named}, read and set as any declared cookie is, and both are
    sealed under the keys the server is given where it starts --
    [Spindle.serve ~keys], [App.start ~keys], [Test.app ~keys] -- so a cookie,
    and the routes that read it, are values made before the secret is read. A
    route that reads one stops the server before it listens when no keys were
    given; one that sets one with none is answered [500], logged. Each value is
    stamped with the second it was made, from the application's [now] as the
    answer is written, and bound to the cookie's name, so it cannot be moved to
    another cookie.
    {b One that fails its signature, its seal or its age is absent} --
    [Cookie.optional] answers [None], and the failure is a [debug] line naming
    the cookie -- because a browser holding one from a retired key or an old
    visit has done nothing wrong. [max_age] is required and is the server's as
    well as the browser's: one made longer ago is refused whatever the browser
    was told, since a copied cookie would otherwise replay for ever; it is also
    the most {!make} writes as its [Max-Age], in whole seconds rounded up, as
    the stamp is read. *)

val signed : max_age:Mtime.Span.t -> string -> 'a Wiretype.t -> 'a named
(** The value readable by the browser, and an HMAC-SHA256 over the name, the
    stamp and the value beside it, as {!Key.sign} makes one but under a key kept
    for cookies, compared in constant time. Raises as {!val-named} does. *)

val encrypted : max_age:Mtime.Span.t -> string -> 'a Wiretype.t -> 'a named
(** The value and its stamp sealed with AES-256-GCM, as {!Key.seal} seals but
    under a key kept for cookies, the name bound to them: a browser can read
    nothing of it. Raises as {!val-named} does. *)

(** What a declared cookie is, for whatever reads one. *)
module Named : sig
  val name : 'a named -> string
  val description : 'a named -> 'a Wiretype.t

  val sealed : 'a named -> bool
  (** Whether it is {!signed} or {!encrypted}. *)

  val unseal :
    'a named -> keys:Key.ring -> now:Ptime.t -> string -> string option
  (** The value a request carried for it, as its description reads it: the value
      itself for a plain cookie, and for a sealed one what it sealed, if its
      signature, its seal and its age hold at [now] under [keys] -- the
      server's, {!Spindle.keys}. *)
end

type t = Cookie_repr.t
(** A cookie to set. *)

val make :
  ?path:string ->
  ?max_age_s:int ->
  ?http_only:bool ->
  ?same_site:same_site ->
  'a named ->
  'a ->
  t
(** [make cookie value]: the value written by the cookie's description, as
    [Wiretype.to_text] writes it; one it will not write -- outside its bounds --
    answers [500], logged, as a sealed cookie with no keys does. [path] defaults
    to ["/"]; [max_age_s] is its [Max-Age], in seconds, and without it the
    cookie lasts as long as the browser's session.

    A plain cookie holds any text: what RFC 6265 leaves out of a value -- a
    space, a quote, a comma, a semicolon, a backslash, a control character, any
    of which could end the cookie early or write an attribute of its own -- is
    percent-encoded, and so is [%], and reading decodes it, so
    [make theme "Kim Li"] is written [theme=Kim%20Li] and read back as
    ["Kim Li"]. A word, a tag or a token keeps its spelling. A value a request
    carries with a [%] not followed by two hex digits is absent, as any cookie
    that does not read is ([Spindle.Cookie.optional]).

    Raises [Invalid_argument] for a path RFC 6265 does not allow -- a control
    character or a semicolon --, a constant written in source. *)

val clear : ?path:string -> 'a named -> t
(** [clear cookie] removes the cookie at [path]: an empty value with no
    lifetime, which is the only way to take one out of a browser. Raises as
    {!make} does for a path. *)
