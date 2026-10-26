(* A dependency of the application's own: a bearer token, read from the
   Authorization header and refused with a 401 when it is missing or is not
   one. Two routes list it beside the framework's inputs, and /docs says
   both need a bearer token.

     curl -H 'Authorization: Bearer ada-token' localhost:8080/me
     curl -H 'Authorization: Bearer ada-token' localhost:8080/notes/1
     curl -i localhost:8080/notes/1 *)

open Spindle.Syntax

let no_such_note =
  Spindle.Refusal.Code.make "no_such_note" ~status:`Not_found
    ~doc:"There is no note by that id that is yours."

(* What the application holds is closed over, not a dependency. The
   dependency hands over the token, and the handler decides whose it is. *)
let people = [ ("ada-token", "Ada"); ("alan-token", "Alan") ]
let notes = [ (1, ("Ada", "Write to Charles")); (2, ("Alan", "Fix the bombe")) ]

let whose token =
  Option.to_result ~none:Bearer_token.please_sign_in
    (List.assoc_opt token people)

(* Somebody else's note is answered as a missing one, so an id says nothing
   about whether a note exists. *)
let note name id =
  match List.assoc_opt id notes with
  | Some (owner, text) when String.equal owner name -> Ok text
  | Some _ | None ->
      Error (Spindle.Refusal.make no_such_note "There is no such note.")

let note_id = Spindle.Path.param "note_id" Wiretype.int

let routes =
  [
    Spindle.get ~summary:"Who the token belongs to"
      Spindle.Path.(s "me")
      (Spindle.Returns.json Wiretype.string)
      (let+ token = Bearer_token.bearer in
       whose token);
    Spindle.get ~summary:"One of your notes" ~refuses:[ no_such_note ]
      Spindle.Path.(s "notes" / note_id)
      (Spindle.Returns.json Wiretype.string)
      (let+ token = Bearer_token.bearer and+ id = Spindle.param note_id in
       let* name = whose token in
       note name id);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Openapi.routes ~title:"Notes" routes)
