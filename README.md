# Spindle

[![ci](https://img.shields.io/github/actions/workflow/status/hyphatech/spindle/ci.yml?branch=main&label=ci)](https://github.com/hyphatech/spindle/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/hyphatech/spindle?label=release)](https://github.com/hyphatech/spindle/releases)
[![license](https://img.shields.io/github/license/hyphatech/spindle)](LICENSE)
![OCaml 5.4+](https://img.shields.io/badge/OCaml-5.4%2B-EC6813?logo=ocaml&logoColor=white)

A direct-style web framework for OCaml 5, on Eio.

Every request runs on its own Eio fibre and a handler reads as ordinary
sequential code. Routes are values, dependencies list what a route reads,
failures are values, and the routes are described as OpenAPI 3.2 and zod
from the same values that serve them. It speaks HTTP/1.1 itself and links no
HTTP library.

## Install

```sh
opam pin add postgres-eio https://github.com/hyphatech/postgres-eio.git
opam pin add https://github.com/hyphatech/rowtype.git
opam pin add https://github.com/hyphatech/wiretype.git
opam pin add https://github.com/hyphatech/spindle.git
```

```lisp
(libraries spindle eio_main)
(preprocess (pps ppx_wiretype))
```

## Quick start

```ocaml
open Spindle.Syntax

type greeting = { text : string } [@@deriving wiretype]

let hello name = Ok { text = "Hello, " ^ name ^ "!" }
let name = Spindle.Path.str "name"

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello" / name)
      (Spindle.Returns.json greeting_json)
      (let+ name = Spindle.param name in
       hello name);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Openapi.docs routes)
```

```console
$ dune exec ./main.exe
Listening on http://localhost:8080 (127.0.0.1 and [::1])

$ curl localhost:8080/hello/Ada
{"text":"Hello, Ada!"}
```

| Request | Answer |
|---|---|
| `GET /hello/Ada` | `200` `{"text":"Hello, Ada!"}` |
| `GET /hello/Ada%20Lovelace` | `200` `{"text":"Hello, Ada Lovelace!"}` |
| `GET /hello` | `404` `{"error":"not_found","message":"There is nothing here."}` |
| `POST /hello/Ada` | `405` `{"error":"method_not_allowed","message":"That is not something you can do here."}` |
| `GET /docs` | `200` the API's interactive reference |
| `GET /openapi.json` | `200` the OpenAPI 3.2 document, `GET /hello/{name}` answering a `greeting` |

The record's description is derived, so it both writes the answer and is its
schema. `let+` gathers the route's inputs, here the path's `name`, and the
body is a plain call to `hello`. Every request is a JSON line on stderr.

## Documentation

The full documentation is at
[hyphatech.github.io/spindle](https://hyphatech.github.io/spindle/), and the
known gaps are in [GAPS.md](GAPS.md).

## Packages

| Package | What it is |
|---|---|
| `spindle` | the framework: routes, dependencies, answers, refusals, cookies, logging, streams, WebSockets, OpenAPI and zod |
| `spindle.http` | HTTP as both ends speak it: heads, bodies, fields, structured fields, multipart, the wire |
| `spindle.client` | calling another server, on `spindle.http` alone, so a program that calls others links no framework |
| `spindle_postgres` | a server's Postgres, over [rowtype](https://github.com/hyphatech/rowtype): bounded connections, a pool and its probe, a failure's refusal |
| `spindle_cli` | an application's command line: its API, described from the routes |

## Contributing

See [AGENTS.md](AGENTS.md).

## Licence

MIT, copyright Hypha Technologies Ltd. See [LICENSE](LICENSE).
