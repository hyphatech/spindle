# Logging

Spindle logs every request for you, and every line your code logs during a
request carries that request's id, so one search finds everything it did.

## Logging from your code

Logging is [logs](https://erratique.ch/software/logs). Make a source per
part of your app, and log with fields of your own:

```ocaml
--8<-- "logging.ml:line"
```

Set the levels and the format from wherever you keep your settings -- here
two environment variables. Spindle reads no environment variable itself:

```ocaml
--8<-- "logging.ml:setup"
```

```sh
APP_LOG='info,shop.billing=debug' APP_LOG_FORMAT=pretty dune exec ./bin/main.exe
```

```sh
curl localhost:8080/charge/500
```

```
10:24:06.913 info  shop.billing [trpw9jmqsz6a] charged  shop.pence=500
10:24:06.913 info  spindle.http [trpw9jmqsz6a] GET /charge/500 200  http.request.method=GET  url.path=/charge/500  http.response.status_code=200  duration=259958  http.response.body.size=8  http.route=/charge/{pence}
```

Your line carries the request's id, `[trpw9jmqsz6a]`, without being handed
it. The second line is the access line Spindle writes for every request:
method, route, status, duration in nanoseconds, and body size.

The format is pretty on a terminal and JSON otherwise. The JSON keys are the
ones Datadog and an OpenTelemetry Collector read without a mapping:

```json
{"timestamp":"2026-10-08T09:24:07.936Z","level":"info","logger.name":"spindle.http","message":"GET /charge/500 200","request_id":"yxh81c3jxdrr","trace_id":"d94e1ed026bb56ed4360738efdab369b","span_id":"aa5e83d9ed21a352","http.request.method":"GET","url.path":"/charge/500","http.response.status_code":200,"duration":199000,"http.response.body.size":8,"http.route":"/charge/{pence}"}
```

A level or format that cannot be read is an error, and the program stops:

```sh
APP_LOG='info,shop=loud' dune exec ./bin/main.exe
```

```text
"loud" is not a log level
```

`Spindle.Log.setup ()` is the same without strings: `?level`, `?sources`
and `?format`.

??? example "The whole app"

    ```ocaml
    --8<-- "logging.ml"
    ```

## What each line contains

- **The request id** is on every line the request causes -- yours, the
  database's, a call to another server's -- and on fibers it forks. To take
  it onto another domain or a systhread, wrap the function in
  `Spindle.Log.carry`.
- **The trace.** Every line has `trace_id` and `span_id`. A request joins
  the caller's W3C `traceparent`, or starts a trace, and `Spindle_client`
  passes it on to the servers it calls.
- **Field names**: put your own under a prefix (`shop.pence`), since keys
  like `status`, `host` and `service` mean something to a collector.
- **Failures**: Spindle logs what a handler raises with `error.kind`,
  `error.message` and `error.stack`. Your own catch-all does the same with
  `~tags:(Spindle.Log.tags (Spindle.Log.raised exn bt))`, taking
  `bt = Printexc.get_raw_backtrace ()` first thing.
- **Levels**: `error` is a bug, `warn` handled but degraded, `info` what
  happened (the access log), `debug` how. A route polled every few seconds
  can log its access line at `Debug` with `Meta.access`, as the health
  probes do.
- **No secrets.** Spindle never logs a header value, a body, a query string
  or a statement's parameters, at any level.

## Tracing

To send traces to an OpenTelemetry Collector, give `Spindle.serve` an
exporter:

```ocaml
Spindle_client.run env @@ fun client ->
Spindle_client.Otlp.run ~clock:(Eio.Stdenv.clock env)
  ~endpoint:"http://collector:4318" ~service:"shop" client
@@ fun trace -> Spindle.serve env ~trace routes
```

Then every request is a span named by its method and route
(`GET /users/{id}`), and so is each `Spindle_client` call and each Postgres
statement. Add spans of your own with:

```ocaml
Spindle.Trace.span "price the order" (fun () -> price order)
```

- The exporter posts OTLP JSON to `/v1/traces` every five seconds, or as
  soon as 512 spans wait. `?ratio` (default `1.0`) is the share of new
  traces kept; a trace joined from a caller is kept when the caller kept it.
- At most 2048 spans wait; past that, and when the collector fails, spans
  are dropped and counted in a `warn` line.
- Spans carry no secrets either: never a query string, header or
  statement parameter.
- To send spans elsewhere, build your own with `Spindle_http.Trace.exporter`.

Next: [static files](static-files.md).
