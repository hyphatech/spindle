(** Who may do what: a policy decides, a dependency enforces.

    A policy is a function of the caller, an action and the object it is done
    to, written in OCaml beside the routes it guards. A route reaches a guarded
    object only through {!can}, which loads it, asks the policy, and hands the
    handler the object or refuses -- so a check is how the handler gets the
    object, and cannot be forgotten.

    {[
    let me = Access.principal ~id:(fun u -> string_of_int u.id) signed_in

    let notes =
      Access.policy "notes" me
        ~action:(function `Read -> "read" | `Delete -> "delete")
        (fun user action (note : note) ->
          match action with
          | `Read when note.shared || note.owner = user.id -> Access.Allow
          | `Delete when note.owner = user.id && not note.locked -> Access.Allow
          | `Read | `Delete -> Access.Deny "not the owner")

    let note = Access.resource notes note_by_id

    let delete =
      Spindle.delete
        Path.(s "notes" / note_id)
        (Returns.empty ~status:`No_content ())
        (let+ n = Access.can `Delete note and+ db = conn in
         remove db n)
    ]}

    A decision reads the caller and the object as this request finds them, so a
    role a person lost is lost at their next request: a caller's roles are read
    from the application's store, not from a token's claims, which hold until
    the token expires.

    Every denial writes one line on the [spindle.access] source, at [Warning]:
    the route, the policy, the action, the caller by the id {!val-principal}
    names them by, and the reason. Nothing of a credential is in it. Every
    decision is also on the request's span, as [spindle.access.policy],
    [spindle.access.action], [spindle.access.subject] and
    [spindle.access.decision]. *)

(** {1 The caller} *)

type 'p principal
(** Who calls, as the application knows them. *)

val principal : id:('p -> string) -> 'p Dep.t -> 'p principal
(** [principal ~id caller]: the caller is what the application's own dependency
    hands over -- read from a session, a bearer token, or both -- and refuses
    with when there is nobody, a [401]; [id] names them in a denial's line, by
    the application's own identifier. Every check of a request reads it once. *)

val caller : 'p principal -> 'p Dep.t
(** The caller, for a route that needs only them: a list of their own notes. *)

(** {1 Policies} *)

type decision =
  | Allow
  | Deny of string
      (** the reason, for the log and never for the client: [not the owner] *)

type ('p, 'a, 'r) policy
(** What a caller ['p] may do -- an action ['a] -- to an object ['r]. *)

val policy :
  string ->
  'p principal ->
  action:('a -> string) ->
  ('p -> 'a -> 'r -> decision) ->
  ('p, 'a, 'r) policy
(** [policy name caller ~action decide]: [name] and [action]'s words say what
    was decided, in the log and on the span. [decide] is pure: what it needs
    beyond the caller and the object -- a membership, a team, a tenant -- is
    loaded with the object, so a policy runs once a check and is tested without
    a server ({!decide}). *)

val decide : ('p, 'a, 'r) policy -> 'p -> 'a -> 'r -> decision
(** What the policy decides, for a test:

    {[
    let decided = function Access.Allow -> "allow" | Access.Deny why -> why

    let () =
      Alcotest.(check string)
        "the owner" "allow"
        (decided (Access.decide notes ada `Delete adas_note))
    ]} *)

(** {1 Checks} *)

type ('p, 'a, 'r) resource
(** An object a policy guards: reachable through {!can} alone. *)

val resource : ('p, 'a, 'r) policy -> 'r Dep.t -> ('p, 'a, 'r) resource
(** [resource policy load]: [load] reads the object as any dependency does --
    from a path parameter, the body, a database -- and refuses as it would,
    [404] for one that is not there. Keep [load] out of reach of the routes, so
    the object is read through its policy and nowhere else. *)

val can : ?deny_as:Refusal.t -> 'a -> ('p, 'a, 'r) resource -> 'r Dep.t
(** [can action resource]: the object, once the caller is read, the object
    loaded and the policy allows [action] -- in that order, so nobody signed in
    is a [401] before anything is looked up. A denial answers [deny_as],
    {!Refusal.not_found} unless given, so someone else's object and a missing
    one are the same answer and an id says nothing of what exists; a route whose
    objects are public anyway gives a [403]. The route declares [deny_as]'s
    code. *)

val forbidden : Refusal.Code.t
(** [403 forbidden]: what {!require} and {!check} refuse with. *)

val require : ('p, 'a, unit) policy -> 'a -> unit Dep.t
(** [require policy action]: a check with no object -- a route only an admin may
    call. A denial is {!forbidden}. *)

val public : Route.t -> Route.t
(** The route, for anyone to call. {!App.make} refuses a route that declares
    nobody who may call it -- reading no caller and no check -- so a page, a
    probe or a document anyone may read says so:

    {[
    Spindle.serve env (List.map Access.public pages @ notes)
    ]}

    and one made public that reads a caller, which is two answers to who may
    call it. *)

val check : ('p, 'a, 'r) policy -> ('a -> 'r -> ('r, Refusal.t) result) Dep.t
(** A check for an object that arrives as a value rather than through a
    dependency -- one an MCP tool's arguments name: the function the caller is
    judged by, the object handed back, or {!forbidden}. The route declares
    {!forbidden}. *)
