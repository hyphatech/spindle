# Describing the API

An API is used by people who never read its source: a front end, a mobile
app, another team. They need to know every path, what each takes, what it
answers and how it fails -- and a description written by hand beside the code
is wrong the first time somebody forgets to update it.

## How it works

**The description is read from the routes.** Everything a route reads,
answers and may refuse with is already a value on it, so Spindle reads the
API's document from the routes themselves. There is nothing to write beside
them, and nothing to forget.

**One walk, three outputs.** An OpenAPI 3.2 document, a reference to read it
by at `/docs`, and a TypeScript module of zod schemas for the client are all
printed from the same walk over the same values, so they cannot disagree with
each other or with the server.

**It says where it is loose.** A route that may read more than it declares,
or a value that may be any JSON, is reported, so a project can require a
description that says everything.

**A build checks it.** The application's own command line writes the
document and the schemas, and `api check` fails when the committed ones are
not what the routes make now -- so a client is never typed against an API
that changed under it.

## A reference at /docs

`Spindle.Openapi.docs` is the document of the routes it is given, at
`/openapi.json`, and the reference over it at `/docs`, as routes served
beside the ones they describe:

```ocaml
--8<-- "openapi.ml:docs"
```

Open `http://localhost:8080/docs`: each route with its summary, its body and
answer as schemas derived from their records, and every code it may refuse
with -- `unknown_language` under `POST /greetings` with its status and what it
means, beside the framework's own, such as `400 invalid` for a body of the
wrong shape. The page's script is compiled into the library and served from
here, so it works offline and asks no other host for anything.

??? example "The whole program"

    ```ocaml
    --8<-- "openapi.ml"
    ```

## The client's schemas

```sh
opam install spindle_cli
```

An application's command line is an executable of its own that makes the
app and hands it to `Spindle_cli.run`:

```ocaml
--8<-- "api_cli.ml:app"
```

```sh
$ dune exec ./api_cli.exe -- api zod -o wire.gen.ts
```

```typescript title="wire.gen.ts"
/* Generated from Notes's routes. Do not edit: change the routes, and generate it again. */

import { z } from "zod/mini";

/** One input that is not what it should be. */
export const ProblemSchema = z.object({
  /** Where: path.x, query.x, body.x. */
  at: z.string(),
  code: z.string(),
  message: z.string(),
});
export type Problem = z.infer<typeof ProblemSchema>;

/** A refusal: the code a client branches on, and a sentence for a person. */
export const RefusalSchema = z.object({
  /** The code. */
  error: z.string(),
  /** A sentence. */
  message: z.string(),
  /** For invalid: each input that is not what it should be. */
  problems: z.optional(z.array(ProblemSchema)),
});
export type Refusal = z.infer<typeof RefusalSchema>;

export const NoteSchema = z.object({
  id: z.int(),
  text: z.string(),
});
export type Note = z.infer<typeof NoteSchema>;

/** Every code a route may refuse with. */
export const CodeSchema = z.enum([
  "busy",
  "internal",
  "invalid",
]);
export type Code = z.infer<typeof CodeSchema>;

/** Each route, by method and pattern: the body it reads, and what it answers. */
export const routes = {
  "GET /notes/{note_id}": {
    body: null,
    answer: { status: 200, schema: NoteSchema },
  },
} as const;
```

Every component is a schema with its type inferred beside it, then the
refusal, the codes a client may branch on, and a table of the routes. A
client parses each answer with the schema its route names, and a server that
gains a field breaks no page already open, since objects strip unknown keys.

`api check` is the step a build runs:

```sh
$ dune exec ./api_cli.exe -- api check --openapi openapi.json --zod wire.gen.ts --strict
```

??? example "The whole program"

    ```ocaml
    --8<-- "api_cli.ml"
    ```

## What an app says about itself

Everything a route is, is a value -- so an app lists its routes without
running any of them:

```ocaml
List.iter (Format.printf "%a@." Spindle.Route.pp_info) (Spindle.App.routes app)
```

```
POST /orders/{order_id}/items  -- Add an item
  path: order_id: integer
  reads: cookie session?: string, query page?: integer, body item
  credentials: session
  returns: 201 item
  refuses: 401 signed_out, 410 gone
  tags: orders
```

`Route.info` is the method, the pattern, the path's parameters and their
types, what the inputs read, the credentials, the answer, every code it may
refuse with, and whether it may read more than it says (`opaque`: a `bind`, or `Dep.of_request` with no
`~needs`).

What a route says of itself is written beside it, because OCaml keeps no
docstrings at run time: `~summary`, `~doc` and `~tags` on every route
builder, and `~meta` for keys a package makes of its own
(`Spindle.Meta.key`, typed, so what is found under a key is what was put
there). An example of a value a route answers goes on its answer,
`Returns.json ~examples`, and of a body it reads on `Spindle.json
~examples`, where each is checked against its description by the type.

**A credential says so.** `Dep.credential ~scheme:"session" d` marks what
`d` reads -- a cookie, a header -- as proof of who is asking, so a document
names the scheme and which routes take it:

```ocaml
let session =
  Spindle.Dep.credential ~scheme:"session"
    (Spindle.Cookie.optional (Spindle.Cookie.named "session" Codec.string))
```

Two lines every route repeats -- the signed-in user, say -- are one
dependency the application names once, not a line copied into each: a long
list is honest, and a copied one drifts.

## The document

`Spindle.Openapi` reads `App.routes`, the routes' descriptions and
the framework's own description of a refusal -- nothing else -- and prints
them two ways from one walk, so the two cannot disagree, and what the
document says a refusal is comes from the description a refusal is written
with. The walk and the two printers of a schema are `wiretype`'s;
what is Spindle's is everything a route adds -- paths, operations, codes,
credentials:

```ocaml
Spindle.Openapi.document ~title:"Orders" app   (* OpenAPI 3.2, as JSON *)
Spindle.Zod.module_ app                        (* TypeScript: zod/mini *)
Spindle.Openapi.report app                     (* what is described loosely *)
```

- **Requests are read decoding and answers encoding**: a member with a
  default may be absent from either, since whether an answer leaves one out
  is a closure nothing can read. Each description with a `kind` is a
  component named by it, so kinds are unique within an application; two
  different descriptions under one kind are an error naming it, unless they
  differ only by direction, when the request's is `<Name>Input`.
- **Codes are responses**, grouped by status, each with what it means; the
  framework's own are added from what a route reads. A credential is a
  security scheme -- HTTP authentication when it reads `Authorization`, its
  scheme its name, and a key in its cookie, header or query otherwise -- and
  a route whose credential may be missing also takes nobody, unless it may
  refuse with a `401`, which says the resource needs one.
- **An enum is its words**, wherever it was made -- `Wiretype.enum`, or
  derived from a variant -- so the document has them exactly, and a bound or
  a kind's `format` is in the schema as it is in the decoder.
- **A union is a case object or a typed `any`.** An object told apart by one
  member is `Wiretype.Object.case_mem`, each case pinned to its tag; a tag
  with an `~absent` is optional in the case it stands for, so a case may
  leave its tag out -- a delivery is `{"pickup": true}` or an address with no
  `pickup`.
  A value that is one of several JSON types is `Wiretype.any` with a
  description per type. `Wiretype.Value.json` says nothing, and is reported.
- **A member left out is a member with a default.** Whether an encoder omits
  a member is a closure nothing can read, so a member the answer may leave
  out says `~absent`, even in a description only ever encoded, or the
  document calls it required.
- **The report is every place described loosely**: a route that may read
  more than it says, and `Wiretype.Value.json`. An empty report is a document
  that says everything, and a project can require one.
- **`/docs`** is `Spindle.Openapi.docs routes`: `GET /openapi.json`, and
  Scalar's reference over it at `GET /docs`, its script compiled into the
  library and served from here, so the page works offline and asks no other
  host for anything. They are routes, added to the ones they describe --
  `Spindle.serve env (routes @ Spindle.Openapi.docs ~title:"Orders" routes)`
  -- and `~at` and `~document` move the page and the document. What is
  described is what is passed, so a site served beside the API stays out of
  its document. A mistake in the descriptions raises before the server
  listens, as a route table does; `Openapi.routes` is the same with a
  `result`, for routes built at run time.

## The command line

An application's command line is a library it calls from an executable of
its own, because OCaml cannot load an application into a generic command:

```ocaml
let () = Spindle_cli.run ~name:"myapp" ~app ()
```

```sh
myapp api openapi [-o FILE]   # the API's document, from the routes
myapp api zod [-o FILE]       # the client's zod schemas, from the routes
myapp api check --openapi FILE --zod FILE [--strict]
```

`app` is how the application makes its app, inside an Eio loop the command
line runs. The app is only described -- no request reaches it -- so it is
made from nothing a request would need: no database, no service it calls.
`api check` writes nothing and fails when either committed file is not what
the routes make, printing the report of what is described loosely -- and
failing on it too with `--strict`. A database's commands are
[`rowtype-migrate`](https://github.com/hyphatech/rowtype)'s.

That is the tutorial. [Going further](../guide/pages.md) takes each of
the rest a page at a time.
