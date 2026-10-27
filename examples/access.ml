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
