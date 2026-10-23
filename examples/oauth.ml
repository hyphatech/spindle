(* A resource server: notes behind OAuth 2.0 bearer tokens, which an
   authorization server elsewhere issues. Each token is checked against the
   issuer's keys, fetched from its metadata; a client that has none is told
   where to read about getting one.

     curl -i localhost:8080/notes
     curl localhost:8080/.well-known/oauth-protected-resource *)

open Spindle.Syntax

(* --8<-- [start:auth] *)
let auth =
  Spindle.Bearer.make ~issuer:"https://id.example.com"
    ~resource:"https://notes.example.com"
(* --8<-- [end:auth] *)

(* --8<-- [start:routes] *)
let me =
  Spindle.get ~summary:"Who the token was issued for"
    Spindle.Path.(s "me")
    (Spindle.Returns.json Wiretype.string)
    (let+ (claims : Spindle.Bearer.claims) = Spindle.Bearer.claims auth in
     Ok claims.subject)

let notes =
  Spindle.get ~summary:"Your notes"
    Spindle.Path.(s "notes")
    (Spindle.Returns.json (Wiretype.list Wiretype.string))
    (let+ () = Spindle.Bearer.scope auth "notes:read" in
     Ok [ "Write to Charles" ])

let routes = [ me; notes ]
(* --8<-- [end:routes] *)

(* --8<-- [start:serve] *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_client.run env @@ fun client ->
  let keys =
    Spindle_client.Oauth.keys client ~issuer:"https://id.example.com"
  in
  Spindle.serve env
    ~resources:[ Spindle.Dep.resource (Spindle.Bearer.keys auth) keys ]
    (routes
    @ [ Spindle.Bearer.metadata auth routes ]
    @ Spindle.Openapi.routes ~title:"Notes" routes)
(* --8<-- [end:serve] *)
