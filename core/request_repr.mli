(** A request as the framework holds it: what {!Request} is, underneath, and the
    one thing only the framework does to one, setting the route it matched. Each
    value {!Request} exports is documented there. *)

(** How reading a body failed: what {!Body.error} is. *)
type body_error = Too_large | Unreadable of string | Busy

type matched = ..
(** The route a request matched, extended by {!Route}, which is built on this
    module and so cannot be named here. *)

(** The one forwarding header a trusted proxy writes, the only one believed. *)
type proxy_header = X_forwarded_for | Forwarded

type t

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

val with_matched : matched -> t -> t
(** The request, once the route table has chosen. *)

val matched : t -> matched option
val meth : t -> Spindle_http.Meth.t
val version : t -> Spindle_http.Head.version
val target : t -> string
val path : t -> string
val query : t -> string -> string option
val queries : t -> string -> string list
val headers : t -> (string * string) list
val header : t -> string -> string option
val cookie : t -> string -> string option
val id : t -> string
val peer : t -> string
val proxied : t -> bool
val proxy_header : t -> proxy_header
val client : t -> string
val now : t -> int
val host : t -> string option
val secure : t -> bool
