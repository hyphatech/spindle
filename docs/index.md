---
hide:
  - navigation
  - toc
---

<div class="hero" markdown>

<div class="hero-text" markdown>

# ![Spindle](assets/logo-light.svg#only-light){ width="320" }![Spindle](assets/logo-dark.svg#only-dark){ width="320" } { #spindle }

<p class="hero-tagline">The Eio-native web framework for modern OCaml.</p>

Fast, ergonomic and RFC-strict. Simple to start, ready for production.

```sh
opam pin add https://github.com/hyphatech/spindle.git
```

[Get started](install.md){ .md-button .md-button--primary }
[Reference](reference.md){ .md-button }

</div>

<div class="hero-code" markdown>

```ocaml
--8<-- "greeting.ml:app"
```

</div>

</div>

<div class="grid cards" markdown>

-   :lucide-sparkles:{ .lg .middle } __Beautiful and idiomatic__

    ---

    Routes are values, inputs are typed, errors are values. Code that reads
    like OCaml, because it is.

-   :lucide-zap:{ .lg .middle } __Performant__

    ---

    Its own HTTP engine and every CPU core from the first request, with no
    tuning.

-   :lucide-waves:{ .lg .middle } __Eio-native__

    ---

    Built on OCaml 5 effects. Straight-line handlers: no promises, no
    monads, no callbacks.

-   :lucide-book-open:{ .lg .middle } __OpenAPI docs via Scalar, out of the box__

    ---

    Interactive docs at `/docs`, generated from your routes and never out
    of date.

    [:octicons-arrow-right-24: OpenAPI](tutorial/openapi.md)

-   :lucide-wand-sparkles:{ .lg .middle } __Front end in sync__

    ---

    Your OCaml types become your front end's schemas, zod included, in
    one command. Change a type and both ends change with it.

    [:octicons-arrow-right-24: Client schemas](tutorial/client-schemas.md)

-   :lucide-braces:{ .lg .middle } __Typed end to end__

    ---

    JSON derived from your types and validated on the way in, with every
    mistake reported at once.

    [:octicons-arrow-right-24: Request bodies](tutorial/bodies.md)

-   :lucide-shield-check:{ .lg .middle } __Battle-tested__

    ---

    Every HTTP requirement it meets is backed by a test. Secure defaults,
    bounded waits, clean shutdowns.

-   :lucide-database:{ .lg .middle } __Postgres included__

    ---

    Typed queries, a pool and transactions, on a driver written in OCaml.

    [:octicons-arrow-right-24: Database](tutorial/database.md)

-   :lucide-boxes:{ .lg .middle } __Batteries included__

    ---

    WebSockets, live updates, sessions, logging, traces, metrics, and
    tests that need no server.

    [:octicons-arrow-right-24: Guides](guide/pages.md)

</div>
