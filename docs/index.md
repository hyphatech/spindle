---
hide:
  - navigation
  - toc
---

# Spindle

<div class="grid" markdown>

<div markdown>

**The beautiful, idiomatic web framework for modern OCaml.**

Performant, Eio-native and battle-tested. OpenAPI and Scalar out of the
box, and zod schemas generated for your front end -- automagically.

```sh
opam install spindle
```

[Get started](install.md){ .md-button .md-button--primary }
[Reference](reference.md){ .md-button }

</div>

```ocaml
--8<-- "greeting.ml:app"
```

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

-   :lucide-book-open:{ .lg .middle } __OpenAPI and Scalar, out of the box__

    ---

    Interactive docs at `/docs`, generated from your routes and never out
    of date.

    [:octicons-arrow-right-24: Describing the API](tutorial/describing.md)

-   :lucide-wand-sparkles:{ .lg .middle } __zod, automagically__

    ---

    One command writes typed zod schemas for every route. Your front end
    and your server can't drift.

    [:octicons-arrow-right-24: The client's schemas](tutorial/describing.md#the-clients-schemas)

-   :lucide-braces:{ .lg .middle } __Typed end to end__

    ---

    JSON derived from your types and validated on the way in, with every
    mistake reported at once.

    [:octicons-arrow-right-24: Bodies](tutorial/bodies.md)

-   :lucide-shield-check:{ .lg .middle } __Battle-tested__

    ---

    Every HTTP requirement it meets is backed by a test. Secure defaults,
    bounded waits, clean shutdowns.

-   :lucide-database:{ .lg .middle } __Postgres included__

    ---

    Typed queries, a pool and transactions, on a driver written in OCaml.

    [:octicons-arrow-right-24: A database](tutorial/database.md)

-   :lucide-boxes:{ .lg .middle } __Batteries included__

    ---

    WebSockets, live updates, sessions, logging, traces, metrics, and
    tests that need no server.

    [:octicons-arrow-right-24: Going further](guide/pages.md)

</div>
