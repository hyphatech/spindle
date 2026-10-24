(* The routes oauth serves, each reading the checked token. *)

open Spindle.Syntax

let me =
  Spindle.get ~summary:"Who the token was issued for"
    Spindle.Path.(s "me")
    (Spindle.Returns.json Wiretype.string)
    (let+ (claims : Spindle.Bearer.claims) =
       Spindle.Bearer.claims Notes_auth.auth
     in
     Ok claims.subject)

let notes =
  Spindle.get ~summary:"Your notes"
    Spindle.Path.(s "notes")
    (Spindle.Returns.json (Wiretype.list Wiretype.string))
    (let+ () = Spindle.Bearer.scope Notes_auth.auth "notes:read" in
     Ok [ "Write to Charles" ])

let routes = [ me; notes ]
