(* A dependency of the application's own: a bearer token, read from the
   Authorization header and refused with a 401 when it is missing or is not
   one. Whose token it is is the caller, which two routes read, and /docs
   says both need a bearer token.

     curl -H 'Authorization: Bearer ada-token' localhost:8080/me
     curl -H 'Authorization: Bearer ada-token' localhost:8080/notes/1
     curl -i localhost:8080/notes/1 *)

open Spindle.Syntax
module Access = Spindle.Access

(* What the application holds is closed over, not a dependency. *)
let people = [ ("ada-token", "Ada"); ("alan-token", "Alan") ]
let notes = [ (1, ("Ada", "Write to Charles")); (2, ("Alan", "Fix the bombe")) ]

(* The caller: whoever the token belongs to. *)
let me =
  Access.principal ~id:Fun.id
    (Spindle.Dep.join
       ~refuses:[ Bearer_token.signed_out ]
       (let+ token = Bearer_token.bearer in
        Option.to_result ~none:Bearer_token.please_sign_in
          (List.assoc_opt token people)))

type action = Read

(* A note is its owner's. *)
let owners =
  Access.policy "notes" me
    ~action:(function Read -> "read")
    (fun name Read (owner, _) ->
      if String.equal owner name then Access.Allow
      else Access.Deny "not the owner")

let note_id = Spindle.Path.param "note_id" Wiretype.int

let note =
  Access.resource owners
    (Spindle.Dep.join
       ~refuses:[ Spindle.Refusal.Code.not_found ]
       (let+ id = Spindle.param note_id in
        Option.to_result ~none:Spindle.Refusal.not_found
          (List.assoc_opt id notes)))

let routes =
  [
    Spindle.get ~summary:"Who the token belongs to"
      Spindle.Path.(s "me")
      (Spindle.Returns.json Wiretype.string)
      (let+ name = Access.caller me in
       Ok name);
    (* Somebody else's note is answered as a missing one, so an id says
       nothing about whether a note exists. *)
    Spindle.get ~summary:"One of your notes"
      Spindle.Path.(s "notes" / note_id)
      (Spindle.Returns.json Wiretype.string)
      (let+ _, text = Access.can Read note in
       Ok text);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Openapi.routes ~title:"Notes" routes)
