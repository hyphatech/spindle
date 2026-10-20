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
opam repo add hypha https://github.com/hyphatech/opam-repository.git
opam install spindle
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

    Multicore by design: your handlers run on every core in parallel, with
    nothing to configure.

    [Multicore :octicons-arrow-right-24:](guide/domains.md){ .md-button }

-   :lucide-waves:{ .lg .middle } __Eio-native__

    ---

    Built on OCaml 5 effects. Straight-line handlers: no promises, no
    monads, no callbacks.

-   :lucide-book-open:{ .lg .middle } __OpenAPI docs via Scalar, out of the box__

    ---

    Interactive docs at `/docs`, generated from your routes and never out
    of date.

    [OpenAPI :octicons-arrow-right-24:](tutorial/openapi.md){ .md-button }

-   :lucide-wand-sparkles:{ .lg .middle } __Front end in sync__

    ---

    Zod or Melange schemas, derived from your OCaml types.

    [Client schemas :octicons-arrow-right-24:](tutorial/client-schemas.md){ .md-button }

-   :lucide-braces:{ .lg .middle } __Typed end to end__

    ---

    JSON derived from your types and validated on the way in, with every
    mistake reported at once.

    [Request bodies :octicons-arrow-right-24:](tutorial/bodies.md){ .md-button }

-   :lucide-shield-check:{ .lg .middle } __RFC-strict__

    ---

    Every HTTP requirement it meets is backed by a test. Secure defaults,
    bounded waits, clean shutdowns.

-   :lucide-database:{ .lg .middle } __Postgres included__

    ---

    Typed queries, a pool and transactions, on a driver written in OCaml.

    [Database :octicons-arrow-right-24:](tutorial/database.md){ .md-button }

-   :lucide-boxes:{ .lg .middle } __Batteries included__

    ---

    WebSockets, live updates, sessions, logging, traces, metrics, and
    tests that need no server.

    [Guides :octicons-arrow-right-24:](guide/pages.md){ .md-button }

</div>
