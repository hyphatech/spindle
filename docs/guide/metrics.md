# Metrics

```ocaml
let metrics = Spindle.Metrics.create () in
Spindle_postgres.Pool.run env db @@ fun pool ->
Spindle_postgres.Pool.measure pool metrics;
Spindle.serve env ~metrics (routes @ Spindle.Metrics.routes metrics)
```

`Spindle.Metrics` is counters, gauges and histograms, each with a fixed
list of label names, registered on a registry the application makes and
passes where it serves. **Counting never contends**: a series keeps a cell
per domain, which only that domain's work adds to, found through the
domain's own table, and a reading sums them; a domain takes a family's lock
only the first time it counts a combination of labels. A gauge is moved up
and down (`add`), or `sampled` -- a function read whenever the metrics are,
so what it measures needs no hook of its own.

- **What the framework counts**, under OpenTelemetry's names:
  `http.server.request.duration` in seconds -- the access line's `duration`
  -- by method, route and status; `http.server.active_requests`;
  `spindle.server.open_connections`; and `spindle.server.body_budget.used`,
  read from the server when the metrics are. `Spindle_postgres.Pool.measure`
  adds the pool's `db.client.connection.count` by state and its
  `pending_requests`, read from `Pool.stats`, a series per pool under its
  `?name`.
- **A label is the program's, never a request's.** A request no route
  answered is counted under no route and never under its path, and a method
  HTTP does not name under `_OTHER`, since every value is a series kept for
  as long as the process lives and a path is anybody's to choose.
- **`Metrics.routes ?at`** is `GET /metrics` in Prometheus's text format, the
  names in its spelling -- dots as underscores, the unit after, a counter's
  `_total`: `http_server_request_duration_seconds` -- its access line at
  `debug` as a probe's is. It is as public as a probe; an application that
  must not show it guards it as any route, with `?guard`, a `unit Dep.t` run
  first whose refusal is the answer. `Metrics.exposition` is the same text,
  for a program that sends it elsewhere.
- **A name that cannot be exposed raises where it is registered**, as a
  constant written in source does, and so does a name registered twice --
  but a `sampled` gauge, whose second reader adds its series to the first's,
  which is how two pools share one name.
