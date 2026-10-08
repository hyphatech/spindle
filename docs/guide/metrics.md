# Metrics

`Spindle.Metrics` counts what your server does and serves it at
`GET /metrics` for Prometheus. Make a registry, pass it to `serve`, and add
its route:

```ocaml
let metrics = Spindle.Metrics.create () in
Spindle_postgres.Pool.run env db @@ fun pool ->
Spindle_postgres.Pool.measure pool metrics;
Spindle.serve env ~metrics (routes @ Spindle.Metrics.routes metrics)
```

```sh
curl localhost:8080/metrics
```

```text
...
# HELP http_server_active_requests Requests being answered
# TYPE http_server_active_requests gauge
http_server_active_requests 1
# HELP http_server_request_duration_seconds How long a request took to answer
# TYPE http_server_request_duration_seconds histogram
http_server_request_duration_seconds_bucket{http_request_method="GET",http_route="/",http_response_status_code="200",le="0.005"} 1
...
```

## Built-in metrics

With `~metrics`, the server counts, under OpenTelemetry's names:

- `http.server.request.duration`, in seconds, by method, route and status;
- `http.server.active_requests`;
- `spindle.server.open_connections`;
- `spindle.server.body_budget.used`, the bytes of request bodies held.

`Spindle_postgres.Pool.measure` adds the pool's
`db.client.connection.count` (by state, `idle` or `used`) and
`db.client.connection.pending_requests`, labelled with the pool's `?name`
(`postgres` by default).

Prometheus sees each name with dots as underscores, its unit after and a
counter's `_total`: `http_server_request_duration_seconds`.

A request no route answered is counted under no route, never its path, and
an unknown method as `_OTHER`, so a client cannot create a series per URL.

## Custom metrics

```ocaml
let orders =
  Spindle.Metrics.counter metrics ~help:"Orders placed" ~labels:[ "kind" ]
    "shop.orders"

let () = Spindle.Metrics.inc orders [ "book" ]
```

```console
# HELP shop_orders_total Orders placed
# TYPE shop_orders_total counter
shop_orders_total{kind="book"} 1
```

- **Counter**: `counter`, then `inc ?by c values`.
- **Gauge**: `gauge`, then `add g values n` (negative to go down); or
  `sampled t name read`, where `read ()` is called whenever the metrics are
  read.
- **Histogram**: `histogram ?buckets`, then `observe h values x`. The
  default buckets are 0.005 to 10 seconds.

Label values are given in the order of `~labels`. Use values your program
chooses, never ones a request does: each value is a series kept for the life
of the process.

These raise `Invalid_argument`, since each is a mistake in your source:

- a name, label or buckets Prometheus cannot read;
- a name registered twice -- except a `sampled` gauge, whose second
  registration adds its series to the first (two pools under one name);
- counting with the wrong number of label values, or a negative `~by`.

## Protecting /metrics

`/metrics` is public unless you guard it. `~guard` is a `unit Dep.t` run
first, whose refusal is the answer:

```ocaml
Spindle.Metrics.routes ~guard:only_the_scraper metrics
```

`~at` serves it at another path, and `Spindle.Metrics.exposition metrics` is
the same text, for sending it elsewhere.
