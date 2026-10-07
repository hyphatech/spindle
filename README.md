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

Spindle and the Hypha libraries under it are pinned from their releases
until opam-repository carries them:

```sh
opam pin add -n https://github.com/hyphatech/postgres-eio.git#0.1.0
opam pin add -n https://github.com/hyphatech/rowtype.git#0.2.0
opam pin add -n https://github.com/hyphatech/wiretype.git#0.1.0
opam pin add https://github.com/hyphatech/spindle.git#0.1.0
```

## Quick start

```ocaml
let routes =
  [
    Spindle.get Spindle.Path.root Spindle.Returns.text
      (Spindle.Dep.return (Ok "Good morning, world!"));
  ]

let () = Eio_main.run @@ fun env -> Spindle.serve env routes
```

## Documentation

[`docs/`](docs/index.md) is a site built by [Zensical](https://zensical.org):
installing it, a tutorial from a first app to a described API with a
database behind it, and a page for each of the rest. Every program a page
shows is a file in [`examples/`](examples/), built with the repository, so a
page cannot show code that does not compile. The reference is each module's
`.mli`, which the site carries as odoc's HTML.

```sh
make docs         # the site, into site/
make docs-serve   # the site at localhost:8000, rebuilt as pages change
```

What is missing or caveated is [GAPS.md](GAPS.md).

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

MIT, copyright Hypha Technologies Ltd; see [LICENSE](LICENSE). RFC 9651's
tests in `test/structured-field-tests/` are under the licence beside them,
and Scalar's script, served by `/openapi`, under its own.
