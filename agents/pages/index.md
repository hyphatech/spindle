# Spindle

The web framework for modern OCaml.

```sh
opam repo add open-opam https://github.com/open-opam/opam-repository.git
opam install spindle
```

```ocaml
open Spindle.Syntax

type greeting = { text : string } [@@deriving wiretype]

let hello name = Ok { text = "Hello, " ^ name ^ "!" }
let name = Spindle.Path.string "name"

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
  Spindle.serve env (routes @ Spindle.Openapi.routes routes)
```

**Beautiful and idiomatic**

Expressive and composable, doing the heavy lifting in just a few lines of
readable code.

**Performant**

Multicore by design, with domains putting every core to work serving
connections in parallel.

**Eio-native**

OCaml 5 effects give every connection its own fiber and keep handlers in
plain direct style.

**OpenAPI docs via Scalar**

Interactive API docs generated from the routes, so they are never out of
date.

**Front end in sync**

Zod or Melange schemas generated from the routes, keeping client and
server aligned.

**Typed end to end**

JSON contracts derived from OCaml types, bounds and docs included.

**HTTP from the ground up**

Built for speed and safety, and extensively tested against RFC standards.

**Dependencies and Resources**

Extend any route with injectable logic and resources that compose and
swap easily.

**Batteries included**

WebSockets, SSE, sessions, rate limits, logs, traces and OpenTelemetry
metrics.
