# OpenAPI

Spindle reads your API's OpenAPI 3.2 document from the routes themselves:
what each route reads, what it answers and every error it may refuse with
are already values on it. You write nothing beside the routes, so the
document never drifts from them.

## Interactive docs with Scalar

`Spindle.Openapi.routes` serves an OpenAPI document of the routes you give
it at `/openapi.json`, and Scalar's interactive reference over it at `/docs`:

```ocaml
--8<-- "openapi.ml:docs"
```

Open `http://localhost:8080/docs` for an interactive OpenAPI reference
([Scalar](https://scalar.com)) generated from your routes: every route, its
body and answer as schemas, and every code it may refuse with. You can send a
request from the browser with **Test Request**.

![The reference at /docs](../assets/scalar.png)

*A bill splitter's `POST /split`: the body's bounds come from `[@min]` and
`[@max]` on its type, and every status the route may answer is listed with
what it means.*

??? example "The app in the screenshot"

    ```ocaml
    --8<-- "split.ml:app"
    ```

- The page's script is compiled into the library and served by your server,
  so it works offline.
- Only the routes you pass are described: `api @ site @ Spindle.Openapi.routes
  api` keeps a static site out of the document.
- `~at` and `~document` move the page and the document.
- Both are public unless you guard them, as `/metrics` is. `~guard` is a
  `unit Dep.t` run first, whose refusal is the answer:
  `Spindle.Openapi.routes ~guard:staff_only api`.
- A mistake in the descriptions -- two different types under one name,
  two paths that make one `operationId`, one path under two parameter
  names, or one operation whose routes answer in different ways or read
  different bodies -- raises before the server listens, and so does an
  `~at` or a `~document` with a parameter in it, which is no one place. For
  routes built at run time, `Spindle.Openapi.make` answers a `result`
  instead.

??? example "The whole app"

    ```ocaml
    --8<-- "openapi.ml"
    ```

## Summaries, tags and examples

What OCaml cannot read from the types, you write on the route:

- `~summary`, `~doc` and `~tags` on every route builder (`Spindle.get`,
  `Spindle.post`, ...), and `~meta` for keys of your own
  (`Spindle.Meta.key`).
- `~examples` on an answer (`Returns.json ~examples`) or a body
  (`Spindle.json ~examples`), checked against the type.
- `Dep.credential ~scheme` marks a cookie or header as proof of who is
  asking, so the document names the scheme and which routes need it:

```ocaml
let session =
  Spindle.Dep.credential ~scheme:"session"
    (Spindle.Cookie.optional (Spindle.Cookie.named "session" Spindle.Codec.string))
```

You can also print what each route reads and answers, without running any
of them. `Spindle.serve` makes the app from your routes for you; to get the
app yourself, call `Spindle.App.make`, which answers an `Error` naming the
route when the table is wrong:

```ocaml
match Spindle.App.make routes with
| Ok app ->
    List.iter (Format.printf "%a@." Spindle.Route.pp_info) (Spindle.App.routes app)
| Error e -> prerr_endline e
```

For a route that reads the `session` above and declares two codes of its
own -- `signed_out` for a request with no session, `gone` for an order that
was deleted -- it prints:

```
POST /orders/{order_id}/items  -- Add an item
  path: order_id: integer
  reads: cookie session?: string, query page?: integer, body item
  credentials: session
  returns: 201 item
  refuses: 410 gone, 401 signed_out, 415 unsupported_media_type
  tags: orders
```

## The OpenAPI document

To write the document to a file, use your app's command line, which the
[next page](client-schemas.md#setting-up-the-command-line) sets up:
`api openapi -o FILE`. From your own code -- a test, a script -- it is two
functions, over the `app` from `App.make`:

```ocaml
Spindle.Openapi.document ~title:"Orders" app (* OpenAPI 3.2, as JSON *)
Spindle.Openapi.report app                   (* what is described loosely *)
```

`document` answers a `result`; its `Error` names two different types
described under one name; two routes whose paths make one
`operationId` (`/a-b` and `/a_b`), which a generated client would give one
name; two whose paths differ only in a parameter's name
(`/items/{id}` and `/items/{item}`), which OpenAPI counts as one path; and
one operation -- routes told apart by a parameter's type -- whose routes
answer in different ways or read different bodies. What to know when you
read the document:

- **Each type with a name is a component.** Names are unique within an app.
  If a type's request and answer forms differ, the request's is
  `<Name>Input`.
- **A field that may be left out is an `option`, or has `[@default v]`**
  (`~absent` when you write a description by hand). This holds even for a
  type you only ever send: otherwise the document calls the field
  required.
- **Codes are responses**, grouped by status, each with what it means; the
  framework's own (`400 invalid`, `503 busy`, ...) are added from what the
  route reads, and a route answering one the document does not list is a
  bug, as it is for a code of your own.
- **An input is one parameter**, however many dependencies read it, and a
  header's name is matched without case. Two that read it as different
  things -- an `int` and a `string`, one value and a list -- are refused
  when the app is made, since one document cannot say both.
- **A body is `required` where an empty one is refused.** An empty JSON
  body is read as `{}`, so one is required unless every member may be left
  out; a raw body is read as it arrived, empty or not, so it never is.
- **Enums and bounds** are in the schema exactly as the decoder checks them.
- **The report lists what is loose**: a route that may read more than it
  declares (a `Dep.bind`, or `Dep.of_request` without `~needs`) and any
  `Wiretype.Value.json`. An empty report means the document says everything.
- A route over the rest of the path, such as `Static.directory`, is left out.

Next: [client schemas](client-schemas.md), your front end's types from the
same routes.
