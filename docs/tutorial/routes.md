# Routes

A route connects a request to a handler: *when somebody sends this method to
this path, call that function*. An app is a list of routes.

## The shape of a route

Every route is written the same way, in four parts:

```ocaml
Spindle.get                                  (* 1. the method *)
  Spindle.Path.(s "todos" / id)              (* 2. the path: /todos/{id} *)
  (Spindle.Returns.json todo_json)           (* 3. what it answers *)
  (let+ id = Spindle.param id in             (* 4. what the handler needs, *)
   get_todo id)                              (*    and the call to it *)
```

1. **The method**: `Spindle.get`, `post`, `put`, `patch` or `delete`.
2. **The path**: `s "todos"` is a fixed part of the URL, and `id` is a
   parameter -- a value taken from the URL, typed: `/todos/7` gives the
   handler the number `7`.
3. **What it answers**: text, JSON of a type, nothing at all.
4. **The handler's arguments and the call**: `let+` reads each thing the
   handler needs from the request, then calls it. When a request does not
   fit -- `/todos/seven` -- Spindle answers it with a `400` saying what was
   wrong, and the handler is never called.

## A route for each method

A small API over a list of todos: read them all, read one, add one, replace
one, delete one.

```ocaml
--8<-- "methods.ml:app"
```

```sh
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
```

What each one shows:

- **`GET /todos`** needs nothing from the request, so it reads
  `Spindle.Dep.return ()` -- nothing -- and calls `list_todos ()`.
- **`GET /todos/{id}`** reads the `id` from the path with `Spindle.param`.
- **`POST /todos`** reads the body as JSON with `Spindle.json draft_json`,
  and answers `201 Created` with `~status`. A body that is not a draft is a
  `400` naming what is wrong in it.
- **`PUT /todos/{id}`** needs two things, joined with `and+`: the `id` from
  the path and the body.
- **`DELETE /todos/{id}`** answers nothing -- `Spindle.Returns.empty ()` --
  which is a `204 No Content`.

The types `todo` and `draft` become JSON with `[@@deriving wiretype]`,
which writes `todo_json` and `draft_json` for you: the descriptions a route
reads a body with and answers with. [Bodies](bodies.md) is the rest of that
story; where the todos are really kept is [a database](database.md).

## Paths

The examples below say `Path` for `Spindle.Path` and `Codec` for
`Spindle.Codec`.

```ocaml
let order_id = Path.str "order_id"               (* any segment, decoded *)
let page = Path.int "page"                       (* a whole number *)
let user_id = Path.int64 "user_id"               (* a 64-bit key *)
let file = Path.rest "file"                      (* every segment left *)
let sku =
  Path.param "sku"
    (Codec.custom ~kind:"sku" ~parse:Sku.of_string
       ~print:Sku.to_string ())                  (* a Sku.t *)

Path.(s "orders" / order_id / s "items")         (* /orders/{order_id}/items *)
Path.(s "orders" / s "recent")                   (* a literal beats {order_id} *)

let order rest = Path.(s "orders" / order_id / rest)  (* a shared prefix *)
order Path.(s "items")
order Path.root                                  (* /orders/{order_id} *)
Path.(s "static" / rest file)                    (* /static/{file*} *)
```

A `string Path.param` is a path of one segment, and `/` joins any two into a
`Path.path`, which `Spindle.param` does not take. A segment arrives
percent-decoded -- `/hello/Kim%20Li` is `"Kim Li"` -- and an empty one is
never a parameter.

**The rest of a path.** `Path.rest` takes every segment left, zero or more,
as a list: `/static/css/site.css` is `["css"; "site.css"]` and `/static` is
`[]`. A segment holding an encoded `/` stays one segment, and a path with an
empty segment in what is left is not matched. It is the last thing in its
path, and it ranks below every literal and parameter at its position, so a
rest route at the root answers whatever no other route names -- from any
depth, since the table goes back up to it when a deeper branch fails. A path
is a resource before it is a method: one that a route names under any method
is that route's, so `GET /orders` where only `POST /orders` is declared is
`405`, never the rest's. The API's document leaves a rest route out: OpenAPI
cannot say a parameter holding a `/`, and what such a route serves is files.

## Matching

A literal beats a parameter wherever the routes are listed, so `/users/me`
answers before `/users/{id}`. The routes are compiled into a table by segment
when the app is made, so what a request costs to match is set by its path's
segments and not by how many routes there are.

A route table that cannot be right is refused when the app is made, naming
the route: two routes of one method that could both answer one URL, a
literal holding a `/`, a parameter named twice, the rest of a path before its
end, a `Spindle.param` for a parameter its route's path does not have, and a
`HEAD` route -- a `HEAD` is answered by the `GET` route, with its head alone.
`Spindle.serve` raises `Invalid_argument` on one before it listens, since a
route table is a constant written in source. (A `Spindle.param` inside a
`Dep.bind` cannot be seen until it runs, where a missing one is a `500`.)

**A parameter that does not parse** -- `/users/abc` for an `int64` -- is a
problem with the request: `400 invalid`, the problem at `path.user_id`, in a
sentence. The literals already chose the route, so the client sent a bad
input. `~or_not_found:()` makes it a URL the route does not answer instead,
for two routes that differ only by a parameter's type; one that may decline
is asked before one that may not.

**Everything else.** A request no route claims is the app's `~not_found`
answer, a handler whose status is its own, or the framework's
`404 not_found`: `Spindle.serve env ~not_found:page routes`. It answers after
the framework has answered what it answers itself -- a `405`, a `501`, a
trailing-slash redirect -- and a rest route at the root takes every path no
other route names, so behind a site it is never reached.

**A trailing slash is another path** -- `404` -- unless
`~trailing_slash:Redirect` asks for a `308` to the path without it.

## Links

A path prints, too, so a link or a redirect is built from the value the
route matches with, and cannot drift from it:

```ocaml
Path.url (order Path.(s "items")) [ Path.arg order_id "Kim Li" ]
                                        (* Ok "/orders/Kim%20Li/items" *)
```

Every segment is percent-encoded, so any text is one segment. Printing is
checked when it runs, not when it compiles -- a parameter left out, given
twice, not the path's own, or printed as nothing is an `Error` naming it --
because a parameter made once and joined into many paths cannot also type a
printer by what follows it in each.

Next: [dependencies](dependencies.md), which is how a handler reads a
parameter, and everything else a request carries.
