(* A session kept on the server: signing in keeps who you are, the page says
   it back, and signing out ends it. The cookie holds only a random id.

   Signing in rotates the id, so one somebody planted in the browser before
   signs nobody in after; signing out deletes the session, so a copy of the
   cookie signs nobody in either.

     curl -c jar -b jar -X POST localhost:8080/sign-in/kim
     curl -c jar -b jar localhost:8080/me
     curl -c jar -b jar -X POST localhost:8080/sign-out *)

open Spindle.Syntax

type visit = { user : string } [@@deriving wiretype]

(* Kept in this process's memory, and in the database with
   Spindle_sqlite.Session.store or Spindle_postgres.Session.store. *)
let session =
  Spindle.Session.create
    ~store:(Spindle.Dep.return (Spindle.Session.memory ()))
    ~idle:Mtime.Span.(14 * day)
    ~absolute:Mtime.Span.(90 * day)
    visit_json

let user = Spindle.Path.string "user"

let routes =
  List.map Spindle.Access.public
    [
      Spindle.post
        Spindle.Path.(s "sign-in" / user)
        Spindle.Returns.text
        (let+ user = Spindle.param user and+ session = session in
         let* () = Spindle.Session.rotate session in
         let* () = Spindle.Session.put session { user } in
         Ok "Signed in.\n");
      Spindle.get
        Spindle.Path.(s "me")
        Spindle.Returns.text
        (let+ session = session in
         let* visit = Spindle.Session.get session in
         match visit with
         | Some { user } -> Ok (Printf.sprintf "You are %s.\n" user)
         | None -> Ok "Nobody is signed in.\n");
      Spindle.post
        Spindle.Path.(s "sign-out")
        Spindle.Returns.text
        (let+ session = session in
         let* () = Spindle.Session.destroy session in
         Ok "Signed out.\n");
    ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
