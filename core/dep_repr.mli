(** A dependency as the framework runs it: what it reads, how it refuses, its
    two stages, and the identity its answer is shared by. What {!Dep} is,
    underneath; the types {!Dep} names are documented there. *)

type body =
  | Raw : body
  | Json : { description : 'a Wiretype.t; examples : 'a list } -> body
  | Stream : body
  | Form : body
  | Multipart : body

type input = {
  name : string;
  required : bool;
  many : bool;
  shape : Codec.shape;
  kind : string option;
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

type context = {
  request : Request.t;
  params : (string * string) list;  (** percent-decoded *)
  outgoing : outgoing;
  table : table option;  (** only for a route that reads something twice *)
}

type credential = { scheme : string; doc : string option; reads : need list }

type listing = {
  owner : int;
  needs : need list;
  codes : Refusal.Code.t list;
  credentials : credential list;
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

val needs_table : 'a t -> bool
(** Whether a route needs answers shared: an identity read twice, or a [bind]
    that may read one again. Any other route allocates nothing for sharing. *)

val make :
  ?inside:listing list ->
  ?needs:need list ->
  ?codes:Refusal.Code.t list ->
  ?credentials:credential list ->
  ?opaque:bool ->
  ?binds:bool ->
  (context -> 'a stage) ->
  'a t
(** A dependency of a new identity, listed after what it is made of. *)

val run :
  'a t ->
  table:bool ->
  Request.t ->
  params:(string * string) list ->
  outgoing:outgoing ->
  body:Body_repr.source ->
  ('a, Refusal.t) result
(** A route's dependency run for one request. Once it returns the body is the
    connection loop's again, so a read left behind reads nothing. *)
