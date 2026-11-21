# Routes

A route says *when somebody sends this method to this path, read these
inputs from the request and pass them to this function*. An app is a list of
routes.

## Anatomy of a route

Every route has four parts:

```ocaml
Spindle.get                                  (* 1. the method *)
  Spindle.Path.(s "todos" / id)              (* 2. the path: /todos/{id} *)
  (Spindle.Returns.json todo_json)           (* 3. what it answers *)
  (let+ id = Spindle.param id in             (* 4. what it reads, *)
   get_todo id)                              (*    and what it does with it *)
```

`let+` and `and+` come from `open Spindle.Syntax` at the top of the file,
with `let*` for a handler's `result`.

1. **The method**: `Spindle.get`, `post`, `put`, `patch` or `delete`. Any
   other method is `Spindle.route`, as in ``Spindle.route `OPTIONS``.
2. **The path**: `s "todos"` is a fixed segment; `id` is a typed parameter,
   so `/todos/7` hands the handler the number `7`.
3. **What it answers**: text, HTML, JSON of a type, nothing, or a response
   you build yourself, such as a redirect. [Request bodies, responses and
   errors](bodies.md) lists them all.
4. **What it reads, and what it does with it**: a value built with `let+`.
   It reads inputs from the request and passes them to your function, the
   handler, here `get_todo`. A request that doesn't fit -- `/todos/seven` --
   gets a `400` saying what is wrong, and the handler never runs.

## One route per method

A small API over a list of todos:

```ocaml
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

open Spindle.Syntax

type todo = { id : int; title : string } [@@deriving wiretype]
type draft = { title : string } [@@deriving wiretype]

(* The handlers know nothing of HTTP, so a test calls them as they are. *)
let list_todos () =
  Ok [ { id = 1; title = "Learn OCaml" }; { id = 2; title = "Try Spindle" } ]

let get_todo id = Ok { id; title = "Learn OCaml" }
let add_todo (draft : draft) = Ok { id = 3; title = draft.title }
let replace_todo id (draft : draft) = Ok { id; title = draft.title }
let delete_todo _ = Ok ()

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
```

```console
$ curl localhost:8080/todos
[{"id":1,"title":"Learn OCaml"},{"id":2,"title":"Try Spindle"}]

$ curl localhost:8080/todos/1
{"id":1,"title":"Learn OCaml"}

$ curl -X POST localhost:8080/todos -H 'content-type: application/json' \
    -d '{"title": "Write a server"}'
{"id":3,"title":"Write a server"}

$ curl -X PUT localhost:8080/todos/1 -H 'content-type: application/json' \
    -d '{"title": "Learn OCaml properly"}'
{"id":1,"title":"Learn OCaml properly"}

$ curl -i -X DELETE localhost:8080/todos/1
HTTP/1.1 204 No Content
...

$ curl localhost:8080/todos/seven
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"path.id","code":"unexpected_type","message":"This must be a whole number."}]}
```

- **`GET /todos`** reads nothing, so its input is `Spindle.Dep.return ()`.
  Written `let+ () = Spindle.Dep.return () in list_todos ()`, it calls
  `list_todos` on every request. `Spindle.Dep.return (list_todos ())` would
  call it once, when the routes are built, and answer that same list for
  ever.
- **`GET /todos/{id}`** reads the `id` with `Spindle.param`.
- **`POST /todos`** reads a JSON body with `Spindle.json draft_json`, and
  answers `201 Created` through `~status`.
- **`PUT /todos/{id}`** reads two things, joined with `and+`.
- **`DELETE /todos/{id}`** answers `Spindle.Returns.empty ()`: `204 No
  Content`.

`[@@deriving wiretype]` writes `todo_json` and `draft_json` from the types.
[Request bodies](bodies.md) covers that; keeping the todos
for real is the [database](database.md) page.

## Path parameters

Below, `Path` is `Spindle.Path`. A parameter is read by a wiretype
description, the one a JSON body's member is read by.

```ocaml
let order_id = Path.string "order_id"               (* any segment *)
let page = Path.int "page"                       (* an int *)
let user_id = Path.int64 "user_id"               (* an int64 *)
let file = Path.rest "file"                      (* every segment left *)
let invoice = Path.param "invoice" (Wiretype.uuid ())  (* a Uuidm.t *)
let year =
  Path.param "year"
    (Wiretype.int_bounded ~min:1900 ~max:2100 ())  (* an int, within bounds *)
let colour =
  Path.param "colour"
    (Wiretype.enum ~kind:"colour" colour_to_string
       [ Red; Green; Blue ])                     (* one of a set of words *)
let sku =
  Path.param "sku"
    (Wiretype.kind ~kind:"sku" ~parse:Sku.of_string
       ~print:Sku.to_string Wiretype.string)     (* a type of your own *)

Path.(s "orders" / order_id / s "items")         (* /orders/{order_id}/items *)
Path.(s "static" / file)                         (* /static/{file*} *)
Path.root                                        (* / *)
```

- Make each parameter once and use it in every path that has it. Read it in
  a route with `Spindle.param order_id`: you pass the parameter, never the
  path built from it.
- Any scalar description reads a segment: `Wiretype.number`, `bool`, `date`
  (`2026-09-30`, read as `(year, month, day)`) and the rest. A segment it
  does not read -- outside its bounds or not -- is a `400` with wiretype's
  problem, or the next route under `~unparsed:Next_route`.
- A segment arrives percent-decoded: `/orders/Kim%20Li` is `"Kim Li"`.
- A `kind`'s `~parse` answers `Ok` the value, or `Error` the sentence a
  client is told: `Error "This is not a SKU."`.
- `Path.rest` takes every segment left, as a list: `/static/css/site.css`
  is `["css"; "site.css"]`, and `/static` is `[]`. It must come last. It is
  left out of the OpenAPI document.

One parameter, read by two routes, one answering text and one JSON:

```ocaml
(* Typed path parameters, answered as text and as JSON.

   A parameter is made once, named, and read with [Spindle.param] in every route
   whose path has it; the name is where a segment that does not parse is
   reported -- /users/abc is a 400 at [path.user_id]. *)

open Spindle.Syntax

let user_id = Spindle.Path.int64 "user_id"
let name = Spindle.Path.string "name"

(* The answer's description is derived from its record, so a name holding a
   quote is still one JSON string. *)
type user = { user_id : string; name : string } [@@deriving wiretype]

(* The handlers take values, not a request: the route below says where each
   value comes from. *)
let user_text id = Ok (Printf.sprintf "User %Ld" id)
let user_answer id name = Ok { user_id = Int64.to_string id; name }

let routes =
  [
    Spindle.get
      Spindle.Path.(s "users" / user_id)
      Spindle.Returns.text
      (let+ id = Spindle.param user_id in
       user_text id);
    Spindle.get
      Spindle.Path.(s "api" / s "users" / user_id / name)
      (Spindle.Returns.json user_json)
      (let+ id = Spindle.param user_id and+ name = Spindle.param name in
       user_answer id name);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
```

```console
$ curl localhost:8080/users/7
User 7

$ curl localhost:8080/api/users/7/Kim%20Li
{"user_id":"7","name":"Kim Li"}

$ curl localhost:8080/users/abc
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"path.user_id","code":"unexpected_type","message":"This must be a whole number."}]}
```

The parameter's name, `user_id`, is where a segment that does not parse is
reported.

## How routes are matched

- **A literal beats a parameter**, whatever the order of the list:
  `/users/me` answers before `/users/{id}`.
- **A parameter that doesn't parse is a `400`** at `path.<name>`. Give it
  `~unparsed:Next_route` (`Path.(s "posts" / int ~unparsed:Next_route
  "key")`) to make it "not this route" instead, so the next route whose
  path matches answers -- `/posts/42` by its number, `/posts/blue-lamp` by
  its name. Routes like these, that differ only by the parameter's type,
  must give it the same name. The OpenAPI document describes them as one
  operation, so they must also answer the same way and read the same body;
  otherwise `Spindle.Openapi.routes` refuses them.
- **A path no route names** is `404`, or your own answer with
  `Spindle.serve env ~not_found:page routes`. `page` is written as a
  route's handler is, with no method or path, and answers a response:
  `Spindle.Dep.return (Ok missing)` for a page that reads nothing, or
  `let+ session = session in ...` for one that greets whoever is signed in.
  A path another method's route names is `405`, with `Allow` listing the
  methods it has.
- **A method no route declares and Spindle does not know** -- `PROPFIND`,
  say -- is `501 Not Implemented`.
- **`OPTIONS`** of a path a route names is answered for you, `204` with that
  `Allow`, unless you declare an `OPTIONS` route there; `OPTIONS *`, which
  asks of the server, is `204` as well.
- **A trailing slash is a different path** (`404`), unless you pass
  `~trailing_slash:Spindle.App.Redirect`, which answers a `308` to the path
  without it.
- **`HEAD`** is answered by the `GET` route; you don't declare it.

A route table that can't be right is refused before the server listens:
`Spindle.serve` raises `Invalid_argument` naming the route. That covers two
routes of one method that could answer the same URL, a parameter named twice
in a path, a `Path.rest` that isn't last, a `Spindle.param` its route's path
doesn't have, and a `HEAD` route. The one `Spindle.param` this cannot check
is one inside `Spindle.Dep.bind`, whose inputs are only known when it runs:
if its route's path lacks the parameter, the request answers `500`.

## Building URLs

Build a link or a redirect from the same path the route matches, so the two
can't drift apart:

```ocaml
let order tail = Path.(s "orders" / order_id / tail)

Path.url (order (Path.s "items")) [ Path.arg order_id "Kim Li" ]
(* Ok "/orders/Kim%20Li/items" *)
```

Each segment is percent-encoded, a segment of `.` or `..` too, which a
browser would otherwise resolve away. A parameter left out, given twice or
not in the path is an `Error` naming it.
