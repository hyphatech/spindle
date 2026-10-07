# Spindle

The beautiful, idiomatic web framework for modern OCaml.

[![ci](https://img.shields.io/github/actions/workflow/status/hyphatech/spindle/ci.yml?branch=main&label=ci)](https://github.com/hyphatech/spindle/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/hyphatech/spindle?label=release)](https://github.com/hyphatech/spindle/releases)
[![license](https://img.shields.io/github/license/hyphatech/spindle)](LICENSE)
![OCaml 5.4+](https://img.shields.io/badge/OCaml-5.4%2B-EC6813?logo=ocaml&logoColor=white)

**Documentation**: [hyphatech.github.io/spindle](https://hyphatech.github.io/spindle/)

**Known gaps**: [GAPS.md](GAPS.md)

## Features

- **Interactive docs**: OpenAPI and Scalar at `/docs`, generated from your routes.
- **zod, automagically**: typed schemas for your front end, from the same routes.
- **Typed end to end**: JSON derived from your types, every input validated.
- **Eio-native**: straight-line handlers on OCaml 5, on every CPU core.
- **Battle-tested**: its own HTTP/1.1 engine, every requirement backed by a test.
- **Batteries included**: Postgres, WebSockets, sessions, logging, traces and metrics.

## Install

```sh
opam pin add https://github.com/hyphatech/spindle.git
```

```lisp
(libraries spindle eio_main)
(preprocess (pps ppx_wiretype))
```

## Example

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
$ curl 'localhost:8080/fahrenheit?celsius=21'
{"fahrenheit":69.8}
```

Open `localhost:8080/docs`:

![The /fahrenheit route in /docs, called with celsius=21 and answering 69.8](docs/assets/scalar.png)

## Contributing

See [AGENTS.md](AGENTS.md).

## Licence

MIT, copyright Hypha Technologies Ltd. See [LICENSE](LICENSE).
