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

type reading = { fahrenheit : float } [@@deriving wiretype]

let to_fahrenheit celsius = Ok { fahrenheit = (celsius *. 9. /. 5.) +. 32. }
let celsius = Spindle.Query.required "celsius" Spindle.Codec.float

let routes =
  [
    Spindle.get
      Spindle.Path.(s "fahrenheit")
      (Spindle.Returns.json reading_json)
      (let+ celsius = celsius in
       to_fahrenheit celsius);
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Openapi.docs routes)
```

```console
$ dune exec ./main.exe
Listening on http://localhost:8080 (127.0.0.1 and [::1])

$ curl 'localhost:8080/fahrenheit?celsius=21'
{"fahrenheit":69.8}
```

| Request | Answer |
|---|---|
| `GET /fahrenheit?celsius=21` | `200` `{"fahrenheit":69.8}` |
| `GET /fahrenheit?celsius=warm` | `400` `{"at":"query.celsius","code":"malformed","message":"This is not a number."}` |
| `GET /fahrenheit` | `400` `{"at":"query.celsius","code":"required","message":"This is required."}` |
| `GET /docs` | `200` the API's interactive reference |
| `GET /openapi.json` | `200` the OpenAPI 3.2 document, `celsius` a required `number` |

`celsius` arrives as a float, or the request is refused before the handler
runs. The record's description is derived, so it writes the answer and is its
schema. `/docs` is the API described from the same routes, and can call it:

![The /fahrenheit route in /docs, called with celsius=21 and answering 69.8](docs/assets/scalar.png)

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
