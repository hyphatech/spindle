# Routes

A route says *when somebody sends this method to this path, call that
function*. An app is a list of routes.

## Anatomy of a route

Every route has four parts:

```ocaml
Spindle.get                                  (* 1. the method *)
  Spindle.Path.(s "todos" / id)              (* 2. the path: /todos/{id} *)
  (Spindle.Returns.json todo_json)           (* 3. what it answers *)
  (let+ id = Spindle.param id in             (* 4. what the handler needs, *)
   get_todo id)                              (*    and the call to it *)
```

1. **The method**: `Spindle.get`, `post`, `put`, `patch` or `delete`.
2. **The path**: `s "todos"` is a fixed segment; `id` is a typed parameter,
   so `/todos/7` hands the handler the number `7`.
3. **What it answers**: text, JSON of a type, or nothing.
4. **The inputs and the call**: `let+` reads what the handler needs from the
   request, then calls it. A request that doesn't fit -- `/todos/seven` --
   gets a `400` saying what is wrong, and the handler never runs.

## One route per method

A small API over a list of todos:

```ocaml
--8<-- "methods.ml:app"
```

```sh
curl localhost:8080/todos
```

```text
[{"id":1,"title":"Learn OCaml"},{"id":2,"title":"Try Spindle"}]
```

```sh
curl localhost:8080/todos/1
```

```text
{"id":1,"title":"Learn OCaml"}
```

```sh
curl -X POST localhost:8080/todos -H 'content-type: application/json' \
    -d '{"title": "Write a server"}'
```

```text
{"id":3,"title":"Write a server"}
```

```sh
curl -X PUT localhost:8080/todos/1 -H 'content-type: application/json' \
    -d '{"title": "Learn OCaml properly"}'
```

```text
{"id":1,"title":"Learn OCaml properly"}
```

```sh
curl -i -X DELETE localhost:8080/todos/1
```

```text
HTTP/1.1 204 No Content
```

```sh
curl localhost:8080/todos/seven
```

```text
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"path.id","code":"malformed","message":"This is not a whole number."}]}
```

- **`GET /todos`** reads nothing, so its input is `Spindle.Dep.return ()`.
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
let sku =
  Path.param "sku"
    (Codec.custom ~kind:"sku" ~parse:Sku.of_string
       ~print:Sku.to_string ())                  (* a type of your own *)

Path.(s "orders" / order_id / s "items")         (* /orders/{order_id}/items *)
Path.(s "static" / rest file)                    (* /static/{file*} *)
Path.root                                        (* / *)
```

- Make a parameter once and use it in every path that has it. `/` joins
  pieces into a path; `Spindle.param` takes the parameter, not the path.
- A segment arrives percent-decoded: `/orders/Kim%20Li` is `"Kim Li"`.
- `Path.rest` takes every segment left, as a list: `/static/css/site.css`
  is `["css"; "site.css"]`, and `/static` is `[]`. It must come last. It is
  left out of the OpenAPI document.

## How routes are matched

- **A literal beats a parameter**, whatever the order of the list:
  `/users/me` answers before `/users/{id}`.
- **A parameter that doesn't parse is a `400`** at `path.<name>`. Give it
  `~or_not_found:()` (`Path.int ~or_not_found:() "id"`) to make it "not this
  route" instead, when two routes differ only by a parameter's type.
- **A path no route names** is `404`, or your own answer with
  `Spindle.serve env ~not_found:page routes`. A path another method's route
  names is `405`.
- **A trailing slash is a different path** (`404`), unless you pass
  `~trailing_slash:Spindle.App.Redirect`, which answers a `308` to the path
  without it.
- **`HEAD`** is answered by the `GET` route; you don't declare it.

A route table that can't be right is refused before the server listens:
`Spindle.serve` raises `Invalid_argument` naming the route. That covers two
routes of one method that could answer the same URL, a parameter named twice
in a path, a `Path.rest` that isn't last, a `Spindle.param` its route's path
doesn't have, and a `HEAD` route.

## Building URLs

Build a link or a redirect from the same path the route matches, so the two
can't drift apart:

```ocaml
let order rest = Path.(s "orders" / order_id / rest)

Path.url (order Path.(s "items")) [ Path.arg order_id "Kim Li" ]
(* Ok "/orders/Kim%20Li/items" *)
```

Each segment is percent-encoded. A parameter left out, given twice or not in
the path is an `Error` naming it.

Next: [dependencies](dependencies.md), everything else a handler can read
from a request.
