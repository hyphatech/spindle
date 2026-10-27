(** A dependency as the framework runs it: what it reads, how it refuses, its
    two stages, and the identity its answer is shared by. What {!Dep} is,
    underneath; the types {!Dep} names are documented there. *)

type body =
  | Raw : { content_types : string list } -> body
  | Json : { description : 'a Wiretype.t; examples : 'a list } -> body
  | Stream : { content_types : string list } -> body
  | Form : body
  | Multipart : body

val content_types : body -> string list
(** The types a body is read in, each [type/subtype], [type/*] or
    [type/*+suffix]; none for any. *)

val takes_content_type : string list -> Request_repr.t -> bool
(** Whether a request names one of these types, or none. *)

type input = {
  name : string;
  required : bool;
  many : bool;
  schema : Wiretype.Schema.t;
  kind : string option;
  default : Wiretype.Value.t option;
}

type file = { name : string; required : bool; many : bool }

type need =
  | Path of string
  | Query of input
  | Header of input
  | Cookie of input
  | Field of input
  | File of file
  | Body of body
  | Custom of { name : string; doc : string }
  | Resource of string

(** Before the body is read: the answer, or what to do with the body once the
    first stage refused nothing. *)
type 'a stage =
  | Now of ('a, Refusal.t) result
  | Later of (Body_repr.held -> ('a, Refusal.t) result)

type outgoing = {
  pattern : string;  (** the route's, for the log *)
  mutable cookies : Cookie.t list;  (** in the order they were set *)
  mutable headers : (string * string) list;
  mutable sent : bool;
      (** set when the answer is made, so a later setting, from a fiber the
          route left behind, is logged as the bug it is *)
}
(** What a route sets on its way out, one per request. *)

val outgoing : string -> outgoing
(** Nothing set yet, for the route of that pattern. *)

type table
(** The answers a request's dependencies have given, by identity. *)

(** A resource's value, by the identity of the dependency that reads it. *)
type binding =
  | Binding : { id : 'a Type.Id.t; name : string; value : 'a } -> binding

(** What {!Dep.val-resource} makes: a binding, or a dependency {!of_resource}
    did not make, refused where it is supplied. *)
type resource = Supplied of binding | Not_a_resource

(** What a read of a resource nobody supplied does. *)
type unsupplied =
  | Refused
      (** a server's: {!Refusal.internal}, naming it, since [App.start] found
          every resource it could see and this one was read inside a [bind] *)
  | Raised  (** a test's: {!Unsupplied}, for [Test.call] to raise on *)

type kept
(** What an app keeps from one request to the next, for {!val-kept}. *)

type resources = {
  supplied : binding list;
  unsupplied : unsupplied;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
  kept : kept;
}
(** What a started app holds for its requests: the resources supplied, its
    monotonic clock, and what it keeps. *)

exception Unsupplied of { owner : int; name : string }
(** A test read the resource of that identity and name, which it was not given.
*)

type context = {
  request : Request.t;
  params : (string * string) list;  (** percent-decoded *)
  outgoing : outgoing;
  table : table option;  (** only for a route that reads something twice *)
  resources : resources;
}

type credential = {
  scheme : string;
  doc : string option;
  scopes : string list;
  reads : need list;
}

type access =
  | Public
  | Caller
  | Checked of { policy : string; action : string option }

type listing = {
  owner : int;
  needs : need list;
  codes : Refusal.Code.t list;
  credentials : credential list;
  access : access list;
}
(** What one identity reads, refuses and proves. *)

type 'a key = { id : 'a Type.Id.t; cached : bool }

type 'a t = {
  key : 'a key option;
      (** [None] for what has nothing of its own to run: [return], [both] *)
  listed : listing list;
      (** every identity it is made of, in order, a repeat as often as it is
          read *)
  opaque : bool;
  binds : bool;  (** holds a [bind], whose reads are known only as it runs *)
  resource : string option;
      (** the name it was made with, by {!of_resource} and nothing else *)
  compute : context -> 'a stage;
      (** what it does, before any answer is shared *)
}

val exec : 'a t -> context -> 'a stage
(** The only thing that runs a dependency: its answer, shared with every other
    use of its identity in the request where the table is kept. *)

val needs : 'a t -> need list
(** What it reads, an identity read twice listed once. *)

val codes : 'a t -> Refusal.Code.t list

val credentials : 'a t -> credential list
(** One a scheme, as {!merge_credentials} makes them. *)

val access : 'a t -> access list
(** Who may call, as what it reads declares: each once, in the order first read.
*)

val mark : access -> 'a t -> 'a t
(** The same answer under an identity of its own, declaring [access]. *)

val merge_credentials : credential list -> credential list
(** Each scheme once, in the order first read: its scopes and what it reads are
    every one's, and its doc the first given. *)

val resources_read : 'a t -> (int * string) list
(** The resources it reads outside a [bind], each once: the identity of the
    dependency that reads it, and its name. *)

val needs_table : 'a t -> bool
(** Whether a route needs answers shared: an identity read twice, or a [bind]
    that may read one again. Any other route allocates nothing for sharing. *)

val make :
  ?inside:listing list ->
  ?needs:need list ->
  ?codes:Refusal.Code.t list ->
  ?credentials:credential list ->
  ?access:access list ->
  ?opaque:bool ->
  ?binds:bool ->
  (context -> 'a stage) ->
  'a t
(** A dependency of a new identity, listed after what it is made of. *)

val of_resource : string -> 'a t
(** As {!Dep.of_resource}. *)

val resource : 'a t -> 'a -> resource
(** As {!Dep.val-resource}. *)

val cookie_keys : Key_repr.ring t
(** The keys signed and encrypted cookies are sealed under: [~keys] where an app
    starts, read as a resource. *)

val is_cookie_keys : int -> bool
(** Whether a resource read by that identity is {!cookie_keys}. *)

val supplied : 'a t -> resources -> 'a option
(** The value the resource read by this dependency was given, if any. *)

val supply :
  resource list ->
  unsupplied:unsupplied ->
  mono_clock:_ Eio.Time.Mono.t ->
  (resources, string) result
(** The resources, timed on [mono_clock] and keeping nothing yet, or a sentence
    saying why not: one {!Dep.val-resource} was given a dependency
    {!of_resource} did not make, or one resource is supplied twice. *)

val kept : make:(unit -> 'a) -> ('a * Mtime.t) t
(** The value an app keeps for this dependency from one request to the next --
    made by [make] the first time one of its requests reads it, so every app has
    its own -- and the app's monotonic clock as it is read. [make] runs under a
    lock, so it does no IO. *)

val is_supplied : resources -> int -> bool
(** Whether the resource read by that identity is among them. *)

val run :
  'a t ->
  table:bool ->
  resources:resources ->
  Request.t ->
  params:(string * string) list ->
  outgoing:outgoing ->
  body:Body_repr.source ->
  ('a, Refusal.t) result
(** A route's dependency run for one request. Once it returns the body is the
    connection loop's again, so a read left behind reads nothing. *)

val of_body :
  ?refuses:Refusal.Code.t list ->
  need:body ->
  (string -> ('a, Refusal.t) result) ->
  'a t
(** A dependency on the body, read whole and handed to the function, described
    as [need]: [Dep.of_body] with [Raw], and the framework's own JSON reader
    with [Json]. *)
