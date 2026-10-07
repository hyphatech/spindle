(* A dependency as the framework runs it: what it reads, how it refuses, its
   two stages, and the identity its answer is shared by. *)

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
  default : string option;
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

(* Before the body is read: the answer, or what to do with the body once the
   first stage refused nothing. *)
type 'a stage =
  | Now of ('a, Refusal.t) result
  | Later of (Body_repr.held -> ('a, Refusal.t) result)

(* What a route sets on its way out, one per request. [sent] is set when the
   answer is made, so a later setting, from a fiber the route left behind,
   is logged as the bug it is. *)
type outgoing = {
  pattern : string;  (** the route's, for the log *)
  mutable cookies : Cookie.t list;  (** in the order they were set *)
  mutable headers : (string * string) list;
  mutable sent : bool;
}

let outgoing pattern = { pattern; cookies = []; headers = []; sent = false }

(* Typed by the identity, so reading back needs no cast. An answer still
   owed a body is the function that reads it, replaced by its result the
   first time it runs. *)
type 'a answer =
  | Answered of ('a, Refusal.t) result
  | Deferred of (Body_repr.held -> ('a, Refusal.t) result)

type entry = Entry : 'a Type.Id.t * 'a answer -> entry
type table = (int, entry) Hashtbl.t

(* [params] are percent-decoded. [table] exists only for a route that reads
   something twice. *)
type context = {
  request : Request.t;
  params : (string * string) list;
  outgoing : outgoing;
  table : table option;
}

type credential = { scheme : string; doc : string option; reads : need list }

type listing = {
  owner : int;
  needs : need list;
  codes : Refusal.Code.t list;
  credentials : credential list;
}

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

let find_answer (type a) table (id : a Type.Id.t) : a answer option =
  match Hashtbl.find_opt table (Type.Id.uid id) with
  | None -> None
  | Some (Entry (id', answer)) -> (
      match Type.Id.provably_equal id id' with
      | Some Type.Equal -> Some answer
      | None -> None)

let store_answer table id answer =
  Hashtbl.replace table (Type.Id.uid id) (Entry (id, answer))

(* The first use to ask reads the body; the rest get what it read. *)
let read_body_once table id k body =
  match find_answer table id with
  | Some (Answered r) -> r
  | Some (Deferred _) | None ->
      let r = k body in
      store_answer table id (Answered r);
      r

let exec d c =
  match (d.key, c.table) with
  | Some { id; cached = true }, Some table -> (
      match find_answer table id with
      | Some (Answered r) -> Now r
      | Some (Deferred k) -> Later (read_body_once table id k)
      | None -> (
          match d.compute c with
          | Now r ->
              store_answer table id (Answered r);
              Now r
          | Later k ->
              store_answer table id (Deferred k);
              Later (read_body_once table id k)))
  | (Some _ | None), (Some _ | None) -> d.compute c

(* An input read twice is one input. *)
let first_listings listed =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun l ->
      if Hashtbl.mem seen l.owner then false
      else (
        Hashtbl.add seen l.owner ();
        true))
    listed

let needs d = List.concat_map (fun l -> l.needs) (first_listings d.listed)
let codes d = List.concat_map (fun l -> l.codes) (first_listings d.listed)

let credentials d =
  List.concat_map (fun l -> l.credentials) (first_listings d.listed)

(* Only when an identity is read twice, or a [bind] may read one again: any
   other route allocates nothing for sharing. *)
let needs_table d =
  d.binds || List.compare_lengths (first_listings d.listed) d.listed <> 0

(* Listed after what it is made of, [inside]. *)
let make ?(inside = []) ?(needs = []) ?(codes = []) ?(credentials = [])
    ?(opaque = false) ?(binds = false) compute =
  let id = Type.Id.make () in
  {
    key = Some { id; cached = true };
    listed = inside @ [ { owner = Type.Id.uid id; needs; codes; credentials } ];
    opaque;
    binds;
    compute;
  }

(* Once the handler returns the body is the loop's again, so a read left
   behind reads nothing. *)
let run d ~table request ~params ~outgoing ~body =
  let table = if table then Some (Hashtbl.create 8) else None in
  match exec d { request; params; outgoing; table } with
  | Now v -> v
  | Later k ->
      let held = Body_repr.hold body ~pattern:outgoing.pattern in
      Fun.protect
        ~finally:(fun () -> Body_repr.end_handler held)
        (fun () -> k held)
