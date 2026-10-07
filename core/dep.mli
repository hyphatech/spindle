(** Dependencies: what a handler needs, computed from the request.

    A ['a t] is a value -- a body of some shape, a query parameter, a signed-in
    person -- that is worked out when a request arrives, or a refusal that
    answers the request instead. A handler lists what it needs with OCaml's own
    binding operators, and every line runs before its body:

    {[
      open Spindle.Syntax

      let+ query = Spindle.json query_json
      and+ now = Spindle.now in
      answer query ~now
    ]}

    {b Two stages.} Everything that does not need the body runs first, and if
    any of it refuses, that refusal answers the request and the body is never
    read: a request with no session is [401] without the server holding a
    megabyte of it. Only then is the body read, once, and what needs it runs.
    Within a stage the list runs left to right. A refusal about the request's
    inputs -- {!Refusal.invalid}, a query parameter missing, a path parameter
    that does not parse -- is collected, and the request is answered with every
    problem at once; any other refusal ends the request there.

    {b A dependency runs once per request}, however many others read it: a value
    has an identity, made with it, and the answer it gave -- a refusal included
    -- is what every other use of it in that request is given. So a signed-in
    person that two dependencies read is one read of the database:

    {[
      let current_user =
        Spindle.Dep.join ~refuses:[ signed_out ]
          (let+ token = bearer in
           Accounts.find pool token)

      let quota = Spindle.Dep.map Quota.of_user current_user

      (* current_user runs once, though the route reads it twice *)
      let+ user = current_user and+ left = quota in ...
    ]}

    What is shared is the value, never its structure: a dependency made again --
    by a function called twice, or inside a {!bind}'s function, which makes its
    values for each request -- is a new one, and shares with nothing. An input
    read twice is listed once ({!needs}, {!codes}, {!credentials}) and its
    problem reported once. {!uncached} is for a value that must be worked out
    again at every use.

    {b A dependency says how it may refuse} -- {!codes} -- as it says what it
    reads, so a route's codes are its own and every one its inputs carry.

    {b A dependency says what it reads} -- {!needs} -- which is how what a route
    takes can be listed without running it. What {!bind} and an {!of_request}
    with no [~needs] read cannot be known without running them, so they say they
    are {!opaque}.

    What the application already holds -- a pool, a client, a configuration --
    is not a dependency. It exists once, at startup, and a route is a function
    of it. *)

type 'a t = 'a Dep_repr.t

(** What a dependency reads of a request. *)
type body = Dep_repr.body =
  | Raw : body
  | Json : { description : 'a Wiretype.t; examples : 'a list } -> body
      (** decoded by [description]; [examples] are for whoever documents it *)
  | Stream : body  (** read as it arrives, by {!Spindle.body_stream} *)
  | Form : body
      (** read whole, as a form: its fields are {!Field}s and its files {!File}s
          ({!Spindle.Form}) *)
  | Multipart : body
      (** read a part at a time, as it arrives ({!Spindle.multipart}) *)

type input = Dep_repr.input = {
  name : string;
  required : bool;
  many : bool;  (** a query parameter given any number of times *)
  shape : Codec.shape;
  kind : string option;  (** the codec's name, if it has one *)
}
(** A query parameter, a header, a cookie or a form's field, as a typed input
    reads it. *)

type file = Dep_repr.file = { name : string; required : bool; many : bool }
(** A form's file, by the name of its field. *)

type need = Dep_repr.need =
  | Path of string  (** a parameter of the route's path, by name *)
  | Query of input
  | Header of input
  | Cookie of input
  | Field of input  (** a form's field, read from its body *)
  | File of file  (** a form's file, read from its body *)
  | Body of body
  | Custom of { name : string; doc : string }
      (** something the framework has no word for -- a session, say *)

val of_request :
  ?needs:need list ->
  ?refuses:Refusal.Code.t list ->
  (Request.t -> ('a, Refusal.t) result) ->
  'a t
(** A dependency of the application's own, read off the request in the first
    stage. [needs] is what it reads; without it the dependency is {!opaque}.
    [refuses] is the codes it may refuse with. *)

val of_body :
  ?content_type:(string -> bool) ->
  ?refuses:Refusal.Code.t list ->
  need:body ->
  (string -> ('a, Refusal.t) result) ->
  'a t
(** A dependency on the body, run in the second stage with the body as it
    arrived. A body the server could not read -- past its limit, broken, or with
    no room to hold it -- has already been refused by then. [content_type] is
    asked of the request's [Content-Type] in the first stage, when it names one:
    [false] is {!Refusal.unsupported_media_type}, with the body never read. *)

val return : 'a -> 'a t
(** A value that reads nothing: what a route with no inputs is given, as
    [Dep.return (Ok "Good morning.")]. The value is made once, when the route
    is, and every request gets that same value; an answer made per request asks
    for an input -- {!Spindle.now}, the request -- and is written with [let+].
*)

val uncached : 'a t -> 'a t
(** The same dependency, worked out again at every use in a request rather than
    once: for a value that must be as late as its use. What it is made of is
    still shared. *)

val refuse : Refusal.t -> 'a t
(** Always refuses, and says it may with that code. *)

val credential : scheme:string -> ?doc:string -> 'a t -> 'a t
(** The same dependency, saying that what it reads proves who is asking -- a
    session cookie, a bearer token -- under the name [scheme], so a document
    generated from the routes names the scheme and which routes need it. What it
    reads is its {!needs}. *)

type credential = Dep_repr.credential = {
  scheme : string;
  doc : string option;
  reads : need list;
}
(** A credential a dependency reads: its scheme's name, and what it reads. *)

val credentials : 'a t -> credential list

val problem : at:string -> code:string -> string -> Refusal.t
(** [problem ~at ~code message]: {!Refusal.invalid} with that one problem -- for
    an input of the application's own, so it is reported with the rest. *)

val map : ('a -> 'b) -> 'a t -> 'b t
val both : 'a t -> 'b t -> ('a * 'b) t

val join : ?refuses:Refusal.Code.t list -> ('a, Refusal.t) result t -> 'a t
(** A dependency whose computation may itself refuse: [join (map check d)] is a
    value checked after it was read, and still says what it reads. [refuses] is
    the codes [check] may refuse with. *)

val bind : 'a t -> ('a -> 'b t) -> 'b t
(** For a dependency that needs another's value to know what to read next. The
    result is {!opaque}: it says what [d] reads, and the codes [d] may refuse
    with, and no more. *)

val needs : 'a t -> need list
(** What it reads, in the order listed: a dependency read twice is listed where
    it is first read. *)

val codes : 'a t -> Refusal.Code.t list
(** The codes it says it may refuse with. The framework's own
    ({!Refusal.Code.framework}) need not be among them: every route may give
    those. *)

val opaque : 'a t -> bool
(** Whether it may read more than {!needs} says. *)
