(** What arrived: a method, a target, headers and a peer.

    A handler rarely reads this directly -- it asks for what it needs through
    {!Dep} -- but a dependency of the application's own is written against it.
    The body is not here: it is read only once the dependencies that do not need
    it have run, and reaches only those that say they do ({!Dep.of_body}).

    A request is read on the domain that answers it. Its URI is parsed the first
    time a query is asked for, and a lazy value forced from two domains at once
    raises, so work handed to another domain is given the values it needs, never
    the request. *)

type t = Request_repr.t

(** Which header a trusted proxy writes, and so the one read from it: a proxy is
    trusted for the header it writes, and one it passes through from the client
    unread is the client's to forge. *)
type proxy_header = Request_repr.proxy_header =
  | X_forwarded_for
      (** [X-Forwarded-For], [X-Forwarded-Host] and [X-Forwarded-Proto] *)
  | Forwarded  (** RFC 7239's [Forwarded], its [for], [host] and [proto] *)

val make :
  ?id:string ->
  ?peer:string ->
  ?client:string ->
  ?proxied:bool ->
  ?proxy_header:proxy_header ->
  ?version:Spindle_http.Head.version ->
  ?host:string ->
  ?headers:(string * string) list ->
  now:(unit -> int) ->
  Spindle_http.Meth.t ->
  string ->
  t
(** [make meth target] for a server adapter or a test. [target] is the path and
    query string as they arrived. Header names are matched without regard to
    case. [now] is the application's clock, in epoch milliseconds. [client]
    defaults to [peer], and [id] to a fresh one. [proxied] says the peer is a
    proxy the server was told to trust (false), and [proxy_header] which header
    it writes ([X_forwarded_for]). [version] is the one the request was sent in
    ([Http_1_1]), and [host] the host its head names (see
    {!Spindle_http.Head.Request.t}) -- its [Host] header, when not given. *)

val id : t -> string
(** This request's id: what every line logged for it carries, and what the
    response's [x-request-id] says. *)

val meth : t -> Spindle_http.Meth.t

val version : t -> Spindle_http.Head.version
(** What the client speaks, which decides what it may be sent: no chunked body,
    no [1xx] and no upgrade for [HTTP/1.0]. *)

val target : t -> string
(** The path and query string as they arrived. *)

val path : t -> string
(** The path as it arrived, percent-encoded as the client wrote it. *)

val query : t -> string -> string option
(** The first value given. *)

val queries : t -> string -> string list
(** Every value given, in order: [?tag=a&tag=b]. *)

val header : t -> string -> string option

val headers : t -> (string * string) list
(** Every field, in the order sent, names lower-cased: for a field that may be
    sent more than once and is read as one list, such as [Connection]. *)

val cookie : t -> string -> string option

val peer : t -> string
(** The address of whoever opened the connection -- which is a proxy, when there
    is one in front. *)

val proxied : t -> bool
(** Whether the peer is a proxy the server was told to trust: the one whose
    {!val-proxy_header} is believed. *)

val proxy_header : t -> proxy_header
(** The header a trusted proxy's word is read from. *)

val host : t -> string option
(** The host the client asked for, lower-cased: what a trusted proxy says in its
    {!val-proxy_header} -- [X-Forwarded-Host], or the last element's [host] in
    [Forwarded] -- the last value, which is the proxy's own where it added a
    line rather than joining the client's; or else the one its head names: an
    absolute-form target's authority, or [Host]. *)

val client : t -> string
(** Who is asking: the peer, or -- only when the peer is a proxy the server was
    told to trust -- the address that proxy says it forwarded for, in its
    {!val-proxy_header}. A header a client can write is a limit a client can
    step around, so an untrusted proxy's header is never read, and a trusted one
    is read in every line of it: the rightmost address the proxy did not write
    itself, and the peer where that hop is [unknown] or hidden. *)

val now : t -> int
(** The application's clock, in epoch milliseconds. *)

val secure : t -> bool
(** Whether a cookie set in answer to this request should be [Secure]: true
    everywhere but a loopback origin.

    [Secure] is the one attribute that can silently throw a cookie away. Safari
    refuses a [Secure] cookie over plain http even on [localhost], and the
    symptom is not an error but a cookie that never arrives -- while a cookie
    for a loopback host has no network to be stolen off. So the flag is decided
    by the origin the browser actually used, and cannot be switched off by
    forgetting a setting. A trusted proxy's word that the browser used [https]
    wins -- [X-Forwarded-Proto], or [Forwarded]'s [proto], as
    {!type-proxy_header} says: a proxy that rewrites [Host] to [localhost] must
    not make a deployment look like somebody's laptop. From anybody else it is a
    header the client wrote, and is not read. *)
