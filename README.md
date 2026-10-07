<h1 align="center">Spindle</h1>

<p align="center">
The beautiful, idiomatic web framework for modern OCaml.
</p>

<p align="center">
  <a href="https://github.com/hyphatech/spindle/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/hyphatech/spindle/ci.yml?branch=main&label=ci" alt="ci"></a>
  <a href="https://github.com/hyphatech/spindle/releases"><img src="https://img.shields.io/github/v/release/hyphatech/spindle?label=release" alt="release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/hyphatech/spindle" alt="license"></a>
  <img src="https://img.shields.io/badge/OCaml-5.4%2B-EC6813?logo=ocaml&logoColor=white" alt="OCaml 5.4+">
</p>

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

<p align="center">
  <a href="https://hyphatech.github.io/spindle/install/">Install</a> |
  <a href="https://hyphatech.github.io/spindle/tutorial/first-app/">Tutorial</a> |
  <a href="https://hyphatech.github.io/spindle/reference/">Reference</a> |
  <a href="GAPS.md">Known gaps</a>
</p>

Run it, and `/docs` is your API, typed, documented and ready to call:

![The /fahrenheit route in /docs, called with celsius=21 and answering 69.8](docs/assets/scalar.png)

- [**OpenAPI and Scalar, out of the box**](https://hyphatech.github.io/spindle/tutorial/describing/):
  interactive docs generated from your routes and never out of date.
- [**zod, automagically**](https://hyphatech.github.io/spindle/tutorial/describing/#the-clients-schemas):
  typed schemas for your front end, so it and your server can't drift.
- [**Typed end to end**](https://hyphatech.github.io/spindle/tutorial/bodies/): JSON derived from your
  types, every input validated, every mistake reported at once.
- [**Eio-native**](https://hyphatech.github.io/spindle/guide/domains/): straight-line handlers on OCaml 5
  effects, and every CPU core from the first request.
- [**Battle-tested**](https://hyphatech.github.io/spindle/guide/serving/): its own HTTP/1.1 engine, every
  requirement it meets backed by a test, secure defaults.
- [**Postgres included**](https://hyphatech.github.io/spindle/tutorial/database/): typed queries, a pool
  and transactions, on a driver written in OCaml.
- [**Batteries included**](https://hyphatech.github.io/spindle/guide/websockets/): WebSockets, live
  updates, sessions, logging, traces, metrics, and tests that need no server.

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

## Contributing

See [AGENTS.md](AGENTS.md).

## Licence

MIT, copyright Hypha Technologies Ltd. See [LICENSE](LICENSE).
