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

    Expressive and composable, doing the heavy lifting in just a few lines
    of readable code.

-   :lucide-zap:{ .lg .middle } __Performant__

    ---

    Multicore by design, with domains putting every core to work serving
    connections in parallel.

    [Multicore :octicons-arrow-right-24:](guide/domains.md){ .md-button }

-   :lucide-waves:{ .lg .middle } __Eio-native__

    ---

    OCaml 5 effects give every connection its own fiber and keep handlers in
    plain direct style.

-   :lucide-book-open:{ .lg .middle } __OpenAPI docs via Scalar__

    ---

    Interactive docs at `/docs`, generated from the routes and never out of
    date.

    [OpenAPI :octicons-arrow-right-24:](tutorial/openapi.md){ .md-button }

-   :lucide-wand-sparkles:{ .lg .middle } __Front end in sync__

    ---

    Zod or Melange schemas generated from the routes, keeping client and
    server aligned.

    [Client schemas :octicons-arrow-right-24:](tutorial/client-schemas.md){ .md-button }

-   :lucide-braces:{ .lg .middle } __Typed end to end__

    ---

    JSON contracts derived from OCaml types, bounds and docs included.

    [Request bodies :octicons-arrow-right-24:](tutorial/bodies.md){ .md-button }

-   :lucide-shield-check:{ .lg .middle } __HTTP from the ground up__

    ---

    Built for speed and safety, and extensively tested against RFC
    standards.

-   :lucide-blocks:{ .lg .middle } __Dependencies and Resources__

    ---

    Extend any route with injectable logic and resources that compose and
    swap easily.

    [Dependencies :octicons-arrow-right-24:](tutorial/dependencies.md){ .md-button }

-   :lucide-boxes:{ .lg .middle } __Batteries included__

    ---

    WebSockets, SSE, sessions, rate limits, logs, traces and OpenTelemetry
    metrics.

    [Guides :octicons-arrow-right-24:](guide/pages.md){ .md-button }

</div>
