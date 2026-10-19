(* A dependency as the framework runs it: what it reads, how it refuses, its
   two stages, and the identity its answer is shared by. *)

type body =
  | Raw : { content_types : string list } -> body
  | Json : { description : 'a Wiretype.t; examples : 'a list } -> body
  | Stream : { content_types : string list } -> body
  | Form : body
  | Multipart : body

(* RFC 8259 §11 defines no parameters. Anything else is refused because a
   browser posts text/plain or a form cross-site without a preflight, and
   JSON only with one. *)
let json_types = [ "application/json"; "application/*+json" ]

(* The types a body is read in, none for any. *)
let content_types = function
  | Raw { content_types } | Stream { content_types } -> content_types
  | Json _ -> json_types
  | Form | Multipart -> []

(* A request that names no type is read; one that names another, or none
   that can be read, is not. *)
let takes_content_type content_types request =
  match (content_types, Request_repr.header request "content-type") with
  | [], _ | _ :: _, None -> true
  | patterns, Some named -> (
      match Spindle_http.Media_type.parse named with
      | Ok m ->
          List.exists (fun p -> Spindle_http.Media_type.matches p m) patterns
      | Error _ -> false)

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
  | Resource of string

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

(* A resource's value, by the identity of the dependency that reads it. *)
type binding =
  | Binding : { id : 'a Type.Id.t; name : string; value : 'a } -> binding

type resource = Supplied of binding | Not_a_resource

(* A server's resources are every one its routes list, which App.start
   checked, so one read without being supplied was read inside a bind: a
   500 that names it. A test is given only the ones it calls for, so such a
   read is the test's bug, which Test.call raises on. *)
type unsupplied = Refused | Raised

(* What an app keeps from one request to the next for a dependency, by the
   dependency's identity: made the first time one of its requests asks. *)
type kept_value = Kept : 'a Type.Id.t * 'a -> kept_value
type kept = { lock : Mutex.t; values : (int, kept_value) Hashtbl.t }

type resources = {
  supplied : binding list;
  unsupplied : unsupplied;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
  kept : kept;
}

exception Unsupplied of { owner : int; name : string }

(* [params] are percent-decoded. [table] exists only for a route that reads
   something twice. *)
type context = {
  request : Request.t;
  params : (string * string) list;
  outgoing : outgoing;
  table : table option;
  resources : resources;
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
  resource : string option;
      (** the name it was made with, by [of_resource] and nothing else *)
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

let resources_read d =
  List.concat_map
    (fun l ->
      List.filter_map
        (function
          | Resource name -> Some (l.owner, name)
          | Path _ | Query _ | Header _ | Cookie _ | Field _ | File _ | Body _
          | Custom _ ->
              None)
        l.needs)
    (first_listings d.listed)

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
    resource = None;
    compute;
  }

let find_resource (type a) (id : a Type.Id.t) resources : a option =
  let value_of (type b) (b_id : b Type.Id.t) (value : b) : a option =
    match Type.Id.provably_equal id b_id with
    | Some Type.Equal -> Some value
    | None -> None
  in
  List.find_map (fun (Binding b) -> value_of b.id b.value) resources.supplied

(* Read in the first stage, as a header is. *)
let of_resource name =
  let id = Type.Id.make () in
  {
    key = Some { id; cached = true };
    listed =
      [
        {
          owner = Type.Id.uid id;
          needs = [ Resource name ];
          codes = [];
          credentials = [];
        };
      ];
    opaque = false;
    binds = false;
    resource = Some name;
    compute =
      (fun c ->
        match (find_resource id c.resources, c.resources.unsupplied) with
        | Some v, _ -> Now (Ok v)
        | None, Raised -> raise (Unsupplied { owner = Type.Id.uid id; name })
        | None, Refused ->
            Now
              (Error
                 (Refusal.internal
                    ~detail:
                      (Printf.sprintf
                         "a dependency read the resource %s, which was not \
                          supplied: Spindle.serve's ~resources supplies it, as \
                          App.start's does"
                         name))));
  }

(* The keys an app seals its signed and encrypted cookies under, given where
   it starts: a resource of the framework's own, so a route that reads such a
   cookie is checked for them as for any other. *)
let cookie_keys : Key_repr.ring t = of_resource "cookie keys"

let is_cookie_keys owner =
  match cookie_keys.key with
  | Some { id; _ } -> Type.Id.uid id = owner
  | None -> false

let supplied (type a) (d : a t) resources : a option =
  match d.key with Some { id; _ } -> find_resource id resources | None -> None

let resource (type a) (d : a t) (value : a) =
  match (d.key, d.resource) with
  | Some { id; _ }, Some name -> Supplied (Binding { id; name; value })
  | (Some _ | None), (Some _ | None) -> Not_a_resource

let kept_nothing () = { lock = Mutex.create (); values = Hashtbl.create 8 }

let supply resources ~unsupplied ~mono_clock =
  let rec check supplied = function
    | [] ->
        Ok
          {
            supplied = List.rev supplied;
            unsupplied;
            mono_clock :> Eio.Time.Mono.ty Eio.Resource.t;
            kept = kept_nothing ();
          }
    | Not_a_resource :: _ ->
        Error
          "Dep.resource was given a dependency Dep.of_resource did not make, \
           which no route can read as a resource"
    | Supplied (Binding b as binding) :: rest ->
        if
          List.exists
            (fun (Binding s) -> Type.Id.uid s.id = Type.Id.uid b.id)
            supplied
        then Error (Printf.sprintf "the resource %s is supplied twice" b.name)
        else check (binding :: supplied) rest
  in
  check [] resources

(* An identity of its own is what each app keeps its value by, so one made
   at the top level is a value of its own in every app. *)
let kept (type a) ~make:(fresh : unit -> a) =
  let id : a Type.Id.t = Type.Id.make () in
  let find_or_make kept =
    Mutex.protect kept.lock (fun () ->
        let found : a option =
          match Hashtbl.find_opt kept.values (Type.Id.uid id) with
          | Some (Kept (k_id, value)) -> (
              match Type.Id.provably_equal id k_id with
              | Some Type.Equal -> Some value
              | None -> None)
          | None -> None
        in
        match found with
        | Some value -> value
        | None ->
            let value = fresh () in
            Hashtbl.replace kept.values (Type.Id.uid id) (Kept (id, value));
            value)
  in
  make (fun c ->
      Now
        (Ok
           ( find_or_make c.resources.kept,
             Eio.Time.Mono.now c.resources.mono_clock )))

let is_supplied resources owner =
  List.exists (fun (Binding b) -> Type.Id.uid b.id = owner) resources.supplied

(* Once the handler returns the body is the loop's again, so a read left
   behind reads nothing. *)
let run d ~table ~resources request ~params ~outgoing ~body =
  let table = if table then Some (Hashtbl.create 8) else None in
  match exec d { request; params; outgoing; table; resources } with
  | Now v -> v
  | Later k ->
      let held = Body_repr.hold body ~pattern:outgoing.pattern in
      Fun.protect
        ~finally:(fun () -> Body_repr.end_handler held)
        (fun () -> k held)
