---
title: Client schemas
---

Your front end's types come from the same routes as the server: a
TypeScript module of [Zod](https://zod.dev) schemas for every body, answer
and error, or, for a front end written in OCaml, a
[Melange](https://melange.re) module with a function per route. Change a
type in OCaml, generate again, and the front end's
compiler shows you every place that must change with it.

## Setting up the command line

Your OCaml project gets a command line of its own: a second executable,
named after the app, built beside the server from the same routes. It never
serves anything; it writes the OpenAPI document and the client schemas into
your front end's folder -- `web/src/` below -- and exits. Install it:

```sh
opam install spindle-cli
```

```
bin/
├── dune
├── routes.ml   the routes, shared by both
├── main.ml     the server
└── notes.ml    the command line
```

```lisp title="bin/dune"
(executables
 (names main notes)
 (libraries spindle spindle-cli eio_main)
 (preprocess
  (pps ppx_wiretype)))
```

`notes.ml` makes the app from the routes and hands it to `Spindle_cli.run`:

```ocaml title="bin/notes.ml"
let () =
  Spindle_cli.run ~name:"notes" ~title:"Notes"
    ~app:(Spindle.App.make Routes.routes) ()
```

The app is only described, never started or served. A database app's routes
need nothing to be described: they read their pool as a
[resource](/spindle/tutorial/dependencies/#resources), which the server
supplies and the command line never asks for.

| Command | What it does |
|---|---|
| `notes api openapi [-o FILE]` | Writes the OpenAPI 3.2 document, to stdout without `-o` |
| `notes api zod [-o FILE]` | Writes the Zod schemas, to stdout without `-o` |
| `notes api melange [-o FILE]` | Writes the OCaml client for Melange, to stdout without `-o` |
| `notes api check --openapi FILE --zod FILE [--melange FILE] [--strict]` | Exits 1 when any file is not what the routes make now |

Every command has `--help`.

## Generating the schemas

```sh
dune build
./_build/default/bin/notes.exe api zod -o web/src/wire.gen.ts
```

```typescript title="web/src/wire.gen.ts"
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

Each type is a schema with its TypeScript type beside it, the error shapes
(`Problem`, `Refusal`) among them; then the codes a client may branch on,
and a table of the routes. Objects strip unknown keys, so a server that gains
a field breaks no client.

## Using them in the front end

The module imports `zod/mini`, which is in Zod 4 and later:

```sh
npm install zod
```

Parse each answer with its schema. A refusal has the same shape on every
route, so one schema reads all of them:

```typescript
import { NoteSchema, RefusalSchema } from "./wire.gen";

const res = await fetch("/notes/1");
if (res.ok) {
  const note = NoteSchema.parse(await res.json()); // a Note, checked
  console.log(note.text);
} else {
  const refusal = RefusalSchema.parse(await res.json());
  console.log(refusal.error, refusal.message); // "invalid", "..."
}
```

`routes["GET /notes/{note_id}"].answer.schema` is the same `NoteSchema`, for
code that works from the table rather than by name.

## An OCaml front end

A front end compiled by Melange calls the routes through a module printed
from them, as the Zod one is:

```sh
./_build/default/bin/notes.exe api melange -o web/src/api.ml
```

Each shape is an OCaml type with the functions that read and write it,
and each route a function named by its operation, its inputs labelled and
typed, answering a promise of a `result`:

```ocaml title="web/src/api.ml"
let get_notes_note_id ?origin ~note_id () = ...
(* (note, Route.error) result Js.Promise.t *)
```

```ocaml
Api.get_notes_note_id ~note_id:1. ()
|> Js.Promise.then_ (fun result ->
       (match result with
       | Ok (note : Api.note) -> Js.log note.text
       | Error (`Refused (r : Api.refusal)) -> Js.log r.message
       | Error e -> Js.log (Api.Route.error_to_string e));
       Js.Promise.resolve ())
```

A path parameter is labelled, a query parameter or a header optional where
the route does not need it, and a body is `~body`; a form's file is a
`Js.File.t`. What a call can come to is `Route.error`: `` `Invalid `` an
input that breaks its description, every problem listed and nothing sent;
`` `Lost `` no answer; `` `Refused `` the server's refusal; and
`` `Unexpected `` an answer the route does not say it gives. An integer with
no bounds within 32 bits is a `float`, which holds every whole number a
browser can. `origin` goes before every path, none unless given, so a page
calls its own origin.

A stream of events and a WebSocket each have a function too, handed what
arrives and answering at once a value to stop it with:

```ocaml
let stream =
  Api.get_ticks ~count:3.
    ~on_event:(function
      | Api.Tick n -> Js.log n
      | Api.Line text -> Js.log text)
    ()

(* Api.Route.Stream.close stream, when the page no longer needs it; and
   Api.Route.Stream.ended stream, a (unit, Route.error) result promise *)

let socket =
  Api.get_chat_room ~room:"r" ~on_message:(fun (m : Api.said) -> Js.log m.text) ()

let sent = Api.Route.Socket.send socket { text = "hi" }
```

A stream is read over `fetch`, so it sends headers and reads a refusal as
any route does, and nothing reconnects it: one that ends is called again by
whoever wants more. A socket's `send` is typed by what the route reads,
checked before it goes and held until the socket opens. A socket that reads
a header has no function, since a browser's WebSocket sends none of the
page's choosing, nor has a route that answers a response of any kind or
reads a body a part at a time; a cookie is the browser's to send. The
module needs no library: it is Melange over the browser's `fetch`.

## Checking them in CI

Commit the schemas and the OpenAPI document, and run `api check` in CI: it
exits 1 when any is not what the routes make now, so a front end is never
typed against an API that changed under it. A Makefile keeps the paths in
one place:

```make title="Makefile"
NOTES   = ./_build/default/bin/notes.exe
OPENAPI = web/src/openapi.gen.json
WIRE    = web/src/wire.gen.ts

wire: ## write the API's document and the client's Zod from the routes
	dune build
	$(NOTES) api openapi -o $(OPENAPI)
	$(NOTES) api zod -o $(WIRE)

check-wire: ## fail when either is not what the routes make
	dune build
	$(NOTES) api check --openapi $(OPENAPI) --zod $(WIRE) --strict
```

`--strict` also fails when anything is described loosely: see
[the report](/spindle/tutorial/openapi/#the-openapi-document).

<details>
<summary>The whole command line, routes included, in one file</summary>

```ocaml
--8<-- "api_cli.ml"
```

</details>

## Generating them from code

The command line calls one function you can call yourself:

```ocaml
Spindle.Zod.schemas app      (* TypeScript: zod/mini *)
Spindle.Melange.client app   (* OCaml for Melange *)
```

Each answers a `result`; its `Error` names two different types described
under one name, two routes whose paths make one `operationId`
(`/a-b` and `/a_b`), two whose paths differ only in a parameter's
name (`/items/{id}` and `/items/{item}`), and routes told apart by a
parameter's type that answer in different ways or read different bodies.
The Melange client's also names where two names in the module would be
one: two components one name in OCaml, an operation named as a
component's function, or a route with two inputs under one label. Routes
told apart by a parameter's type are one entry, whose body and answer are
either route's.

That is the tutorial. The [guides](/spindle/guide/pages/) take each of the
rest a page at a time.
