(* A route for each method on one resource, a list of todos: GET reads them,
   POST adds one, PUT replaces one and DELETE removes one. Where todos are
   kept is the database's job, so each handler answers as if it had done it.

     curl localhost:8080/todos
     curl localhost:8080/todos/1
     curl -X POST localhost:8080/todos -H 'content-type: application/json' \
       -d '{"title": "Write a server"}'
     curl -X PUT localhost:8080/todos/1 -H 'content-type: application/json' \
       -d '{"title": "Learn OCaml properly"}'
     curl -X DELETE localhost:8080/todos/1 *)

(* --8<-- [start:app] *)
open Spindle.Syntax

type todo = { id : int; title : string } [@@deriving wiretype]
type draft = { title : string } [@@deriving wiretype]

(* The handlers know nothing of HTTP, so a test calls them as they are. *)
let list_todos () =
  Ok [ { id = 1; title = "Learn OCaml" }; { id = 2; title = "Try Spindle" } ]

let get_todo id = Ok { id; title = "Learn OCaml" }
let add_todo (draft : draft) = Ok { id = 3; title = draft.title }
let replace_todo id (draft : draft) = Ok { id; title = draft.title }
let delete_todo _id = Ok ()

(* A parameter is made once, so every route whose path has it reads it the
   same way. *)
let id = Spindle.Path.int "id"

let routes =
  [
    Spindle.get
      Spindle.Path.(s "todos")
      (Spindle.Returns.json (Wiretype.list todo_json))
      (let+ () = Spindle.Dep.return () in
       list_todos ());
    Spindle.get
      Spindle.Path.(s "todos" / id)
      (Spindle.Returns.json todo_json)
      (let+ id = Spindle.param id in
       get_todo id);
    Spindle.post
      Spindle.Path.(s "todos")
      (Spindle.Returns.json ~status:`Created todo_json)
      (let+ draft = Spindle.json draft_json in
       add_todo draft);
    Spindle.put
      Spindle.Path.(s "todos" / id)
      (Spindle.Returns.json todo_json)
      (let+ id = Spindle.param id and+ draft = Spindle.json draft_json in
       replace_todo id draft);
    Spindle.delete
      Spindle.Path.(s "todos" / id)
      (Spindle.Returns.empty ())
      (let+ id = Spindle.param id in
       delete_todo id);
  ]

let () = Eio_main.run @@ fun env -> Spindle.serve env routes
(* --8<-- [end:app] *)
