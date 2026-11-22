# Access control

Decide who may do what to which object. A **policy** is a function you
write; a **check** is a dependency that enforces it, so a route gets an
object only once its policy allows the action.

```ocaml title="access.ml"
(* Who may do what to a note: its owner reads and deletes it, anyone signed
   in reads a shared one, nobody deletes a locked one, and an admin reads
   every one and sees how many there are.

     curl -H 'Authorization: Bearer ada-token' localhost:8080/notes/1
     curl -i -X DELETE -H 'Authorization: Bearer alan-token' localhost:8080/notes/1
     curl -H 'Authorization: Bearer grace-token' localhost:8080/admin/count *)

open Spindle.Syntax
module Access = Spindle.Access

type person = { id : int; admin : bool }
type note = { owner : int; text : string; shared : bool; locked : bool }

let people =
  [
    ("ada-token", { id = 1; admin = false });
    ("alan-token", { id = 2; admin = false });
    ("grace-token", { id = 3; admin = true });
  ]

let notes =
  [
    (1, { owner = 1; text = "Write to Charles"; shared = false; locked = false });
    (2, { owner = 2; text = "Fix the bombe"; shared = true; locked = false });
    ( 3,
      { owner = 1; text = "The engine's plans"; shared = false; locked = true }
    );
  ]

(* Who calls: the person the token belongs to, read once a request however
   many checks read them, and named in a denial's log line by their id. *)
let me =
  Access.principal
    ~id:(fun p -> string_of_int p.id)
    (Spindle.Dep.join
       ~refuses:[ Bearer_token.signed_out ]
       (let+ token = Bearer_token.bearer in
        Option.to_result ~none:Bearer_token.please_sign_in
          (List.assoc_opt token people)))

type action = Read | Delete

(* The rule, whole, in one place. *)
let policy =
  Access.policy "notes" me
    ~action:(function Read -> "read" | Delete -> "delete")
    (fun person action note ->
      match action with
      | Read when person.admin || note.shared || note.owner = person.id ->
          Access.Allow
      | Delete when note.locked -> Access.Deny "locked"
      | Delete when note.owner = person.id -> Access.Allow
      | Read | Delete -> Access.Deny "not the owner")

let note_id = Spindle.Path.param "note_id" Wiretype.int

(* The note is loaded as any input is, and handed to its policy: a route
   reaches it through Access.can and no other way. *)
let note =
  Access.resource policy
    (Spindle.Dep.join
       ~refuses:[ Spindle.Refusal.Code.not_found ]
       (let+ id = Spindle.param note_id in
        Option.to_result ~none:Spindle.Refusal.not_found
          (List.assoc_opt id notes)))

type admin = Count

let admin =
  Access.policy "admin" me
    ~action:(function Count -> "count")
    (fun person Count () ->
      if person.admin then Access.Allow else Access.Deny "no admin")

let routes =
  [
    Spindle.get ~summary:"A note"
      Spindle.Path.(s "notes" / note_id)
      (Spindle.Returns.json Wiretype.string)
      (let+ n = Access.can Read note in
       Ok n.text);
    (* Someone else's note is answered as a missing one, so an id says
       nothing of what exists. *)
    Spindle.delete ~summary:"Delete a note"
      Spindle.Path.(s "notes" / note_id)
      (Spindle.Returns.empty ~status:`No_content ())
      (let+ _ = Access.can Delete note in
       Ok ());
    (* A list is the application's own lookup, for the caller. *)
    Spindle.get ~summary:"Your notes"
      Spindle.Path.(s "notes")
      (Spindle.Returns.json (Wiretype.list Wiretype.string))
      (let+ person = Access.caller me in
       Ok
         (List.filter_map
            (fun (_, n) -> if n.owner = person.id then Some n.text else None)
            notes));
    Spindle.get ~summary:"How many notes there are"
      Spindle.Path.(s "admin" / s "count")
      (Spindle.Returns.json Wiretype.int)
      (let+ () = Access.require admin Count in
       Ok (List.length notes));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Openapi.routes ~title:"Notes" routes)
```

## The caller

`Access.principal ~id me` names who calls, from a dependency of your own:
a session, a bearer token, or both. It refuses when there is nobody, with
your `401`. `~id` is how a denial's log line names them -- your own
identifier, never anything of their credential. However many checks a
route makes, the caller is read once a request.

A route that needs only the caller -- a list of their own notes -- reads
`Access.caller me`.

## The policy

`Access.policy name caller ~action decide`: `decide` takes the caller, an
action and the object, and answers `Allow` or `Deny reason`. It is pure: a
role is a field of the caller, ownership a field of the object, and a
membership or a tenant is loaded with the object, so the rule is one
`match` in one place.

Read roles from your database, not from a token's claims: a decision is
made on every request with what it reads then, so a role someone loses is
lost at their next request, where a claim holds until the token expires.

## Checks

| Check | Hands over | A denial is |
|---|---|---|
| `Access.can action resource` | the object | `404`, the same answer as a missing object, unless `~deny_as` gives another |
| `Access.require policy action` | `()` | `403 forbidden` |
| `Access.check policy` | a function judging an object you hold | `403 forbidden` |

`Access.resource policy load` hands the object's loader to its policy. Keep
the loader out of your routes' reach, so `Access.can` is the only way to
the object: a check is then how a handler gets what it works on, and
cannot be forgotten.

`can` reads the caller before the object, so nobody signed in is a `401`
before anything is looked up. A denial answers as a missing object by
default, so an id tells a stranger nothing about what exists; a route
whose objects are public anyway gives `~deny_as` a `403` of its own.

`Access.check` is for an object that arrives as a value -- named in a
body, or in an MCP tool's arguments -- rather than loaded by a dependency.

Each check declares what it refuses with, so the route's
[document](../tutorial/openapi.md) lists it.

## Who may call a route

Who may call a route is what it reads -- the dependencies are the whole of
it:

| A route reads | Who may call it |
|---|---|
| `Access.can`, `require` or `check` | whoever the policy allows |
| `Access.caller`, `Bearer.claims` or `Bearer.scope` | whoever is signed in |
| none of these | anyone |

A page anyone may read is written as any route is, and an application with
no access control writes nothing of it.

The [document](../tutorial/openapi.md) says it for each operation, as
`x-spindle-access`:

```json
"delete": {
  "x-spindle-access": [{ "policy": "notes", "action": "delete" }],
  ...
}
```

one entry a check, `[]` for a route that reads only the caller, and none for
one anyone may call.

## A check forgotten

A route meant to be guarded whose check was forgotten is anyone's -- the
commonest break of access control, and the one nobody sees.
`Access.unguarded` lists the routes that read no check, so a test says
which are meant to be anyone's, and fails, naming it, when another joins
them:

```ocaml
let test_only_these_are_public () =
  Alcotest.(check (list string))
    "public routes" [ "GET /"; "GET /about" ]
    (Spindle.Access.unguarded routes)
```

## Lists

Which objects a caller may see is your own query, written beside its
route, as `GET /notes` does above. A policy judges one object; filtering a
table by it is your database's work.

## The log

A denial writes one line on the `spindle.access` source, at `warn`:

```console
DELETE /notes/1: notes: delete denied to 2: not the owner
```

with the route, the policy, the action, the caller's id and the reason as
fields. An allow writes no line. Every decision is on the request's span,
as `spindle.access.policy`, `spindle.access.action`,
`spindle.access.subject` and `spindle.access.decision`.

## Testing a policy

`Access.decide` answers what a policy decides, with no server:

```ocaml
let ada = { id = 1; admin = false }
let adas = { owner = 1; text = "Write to Charles"; shared = false; locked = false }

let decided = function Access.Allow -> "allow" | Access.Deny why -> why

let test_the_owner_deletes () =
  Alcotest.(check string) "unlocked" "allow"
    (decided (Access.decide policy ada Delete adas));
  Alcotest.(check string) "locked" "locked"
    (decided (Access.decide policy ada Delete { adas with locked = true }))
```
