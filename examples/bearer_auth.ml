(* A dependency of the application's own: a bearer token, read from the
   Authorization header and refused with a 401 when it is missing or is not
   one. Two routes list it beside the framework's inputs, and /docs says
   both need a bearer token.

     curl -H 'Authorization: Bearer ada-token' localhost:8080/me
     curl -H 'Authorization: Bearer ada-token' localhost:8080/notes/1
     curl -i localhost:8080/notes/1 *)

open Spindle.Syntax

let ( let* ) = Result.bind

(* A 401 names how to authenticate, in WWW-Authenticate, so the code carries
   the challenge. *)
let signed_out =
  Spindle.Refusal.Code.make "signed_out" ~status:`Unauthorized
    ~challenge:{|Bearer realm="notes"|} ~doc:"No valid bearer token was sent."

let no_such_note =
  Spindle.Refusal.Code.make "no_such_note" ~status:`Not_found
    ~doc:"There is no note by that id that is yours."

let please_sign_in = Spindle.Refusal.make signed_out "Please sign in."

(* Made of the framework's own header input, read as credentials -- a
   scheme compared without case, so "bearer abc" is a bearer token as
   "Bearer abc" is -- and [join] turns a check that fails into a refusal of
   the request. The header is optional rather than required because a
   missing token is a 401, not a malformed request. [credential] names the
   scheme for the document, which reads the rest: Authorization is HTTP
   authentication, and a 401 means the token is needed. *)
let bearer =
  Spindle.Dep.credential ~scheme:"bearer"
    (Spindle.Dep.join ~refuses:[ signed_out ]
       (let+ credentials =
          Spindle.Header.optional "authorization" Spindle.Codec.credentials
        in
        match credentials with
        | Some { scheme = "bearer"; value = Token68 token } -> Ok token
        | Some _ | None -> Error please_sign_in))

(* What the application holds is closed over, not a dependency. The
   dependency hands over the token, and the handler decides whose it is. *)
let people = [ ("ada-token", "Ada"); ("alan-token", "Alan") ]
let notes = [ (1, ("Ada", "Write to Charles")); (2, ("Alan", "Fix the bombe")) ]

let whose token =
  Option.to_result ~none:please_sign_in (List.assoc_opt token people)

(* Somebody else's note is answered as a missing one, so an id says nothing
   about whether a note exists. *)
let note name id =
  match List.assoc_opt id notes with
  | Some (owner, text) when String.equal owner name -> Ok text
  | Some _ | None ->
      Error (Spindle.Refusal.make no_such_note "There is no such note.")

let note_id = Spindle.Path.param "note_id" Spindle.Codec.int

let routes =
  [
    Spindle.get ~summary:"Who the token belongs to"
      Spindle.Path.(s "me")
      (Spindle.Returns.json Wiretype.string)
      (let+ token = bearer in
       whose token);
    Spindle.get ~summary:"One of your notes" ~refuses:[ no_such_note ]
      Spindle.Path.(s "notes" / note_id)
      (Spindle.Returns.json Wiretype.string)
      (let+ token = bearer and+ id = Spindle.param note_id in
       let* name = whose token in
       note name id);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Openapi.docs ~title:"Notes" routes)
