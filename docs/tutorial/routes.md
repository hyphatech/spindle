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

`let+` and `and+` come from `open Spindle.Syntax` at the top of the file.

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
--8<-- "methods.ml:app"
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
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"path.id","code":"malformed","message":"This is not a whole number."}]}
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
[Request bodies](bodies.md) covers that; keeping the todos for real is
the [database](database.md) page.

## Path parameters

Below, `Path` is `Spindle.Path` and `Codec` is `Spindle.Codec`.

```ocaml
let order_id = Path.str "order_id"               (* any segment *)
let page = Path.int "page"                       (* an int *)
let user_id = Path.int64 "user_id"               (* an int64 *)
let file = Path.rest "file"                      (* every segment left *)
let invoice = Path.param "invoice" Codec.uuid    (* a UUID, as a Uuidm.t *)
let colour =
  Path.param "colour"
    (Codec.enum ~kind:"colour" colour_to_string
       [ Red; Green; Blue ])                     (* one of a set of words *)
let sku =
  Path.param "sku"
    (Codec.custom ~kind:"sku" ~parse:Sku.of_string
       ~print:Sku.to_string ())                  (* a type of your own *)

Path.(s "orders" / order_id / s "items")         (* /orders/{order_id}/items *)
Path.(s "static" / file)                         (* /static/{file*} *)
Path.root                                        (* / *)
```

- Make each parameter once and use it in every path that has it. Read it in
  a route with `Spindle.param order_id`: you pass the parameter, never the
  path built from it.
- `Codec` also has `float`, `bool` and `date` (`2026-09-30`, read as
  `(year, month, day)`).
- A segment arrives percent-decoded: `/orders/Kim%20Li` is `"Kim Li"`.
- A `custom` codec's `~parse` answers `Ok` the value, or `Error` the
  sentence a client is told: `Error "This is not a SKU."`.
- `Path.rest` takes every segment left, as a list: `/static/css/site.css`
  is `["css"; "site.css"]`, and `/static` is `[]`. It must come last. It is
  left out of the OpenAPI document.

One parameter, read by two routes, one answering text and one JSON:

```ocaml
--8<-- "path_params.ml:routes"
```

```console
$ curl localhost:8080/users/7
User 7

$ curl localhost:8080/api/users/7/Kim%20Li
{"user_id":"7","name":"Kim Li"}

$ curl localhost:8080/users/abc
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"path.user_id","code":"malformed","message":"This is not a whole number."}]}
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
  otherwise `Spindle.Openapi.docs` refuses them.
- **A path no route names** is `404`, or your own answer with
  `Spindle.serve env ~not_found:page routes`. A path another method's route
  names is `405`, with `Allow` listing the methods it has.
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

Next: [dependencies](dependencies.md), everything else a handler can read
from a request.
