# Client schemas

Your front end's types come from the same routes as the server: a
TypeScript module of [zod](https://zod.dev) schemas for every body, answer
and error. Change a type in OCaml, generate again, and the front end's
compiler shows you every place that must change with it.

## Setting up the command line

Your OCaml project gets a command line of its own: a second executable,
named after the app, built beside the server from the same routes. It never
serves anything; it writes the OpenAPI document and the client schemas into
your front end's folder -- `web/src/` below -- and exits.

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
 (libraries spindle spindle_cli eio_main)
 (preprocess
  (pps ppx_wiretype)))
```

`notes.ml` makes the app from the routes and hands it to `Spindle_cli.run`:

```ocaml title="bin/notes.ml"
let app _env ~sw:_ = Spindle.App.make Routes.routes
let () = Spindle_cli.run ~name:"notes" ~title:"Notes" ~app ()
```

The app is only described, never served, so make it from nothing a request
needs: no database, no service it calls.

| Command | What it does |
|---|---|
| `notes api openapi [-o FILE]` | Writes the OpenAPI 3.2 document, to stdout without `-o` |
| `notes api zod [-o FILE]` | Writes the zod schemas, to stdout without `-o` |
| `notes api check --openapi FILE --zod FILE [--strict]` | Exits 1 when either file is not what the routes make now |

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

Each type is a schema with its TypeScript type beside it, then the refusal,
the codes a client may branch on, and a table of the routes. Objects strip
unknown keys, so a server that gains a field breaks no client.

## Checking them in CI

Commit the schemas and the OpenAPI document, and run `api check` in CI: it
exits 1 when either is not what the routes make now, so a front end is never
typed against an API that changed under it. A Makefile keeps the paths in one place:

```make title="Makefile"
NOTES   = ./_build/default/bin/notes.exe
OPENAPI = web/src/openapi.gen.json
WIRE    = web/src/wire.gen.ts

wire: ## write the API's document and the client's zod from the routes
	dune build
	$(NOTES) api openapi -o $(OPENAPI)
	$(NOTES) api zod -o $(WIRE)

check-wire: ## fail when either is not what the routes make
	dune build
	$(NOTES) api check --openapi $(OPENAPI) --zod $(WIRE) --strict
```

`--strict` also fails when anything is described loosely: see
[the report](openapi.md#the-openapi-document).

??? example "The whole command line, routes included, in one file"

    ```ocaml
    --8<-- "api_cli.ml"
    ```

## Generating them from code

The command line calls one function you can call yourself:

```ocaml
Spindle.Zod.module_ app   (* TypeScript: zod/mini *)
```

It answers a `result`; its `Error` names two different types described
under one name.

That is the tutorial. The [guides](../guide/pages.md) take each of the
rest a page at a time.
