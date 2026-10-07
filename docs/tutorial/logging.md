# Logging

When something goes wrong in production, the log is what you have: which
request it was, what it touched, what failed and where. Spindle logs every
request without being asked, and makes every line it or your code writes
findable by the request that caused it.

## How logging works

**One line per request, written by the server.** The access line says the
method, the route, the status, how long it took and how big the answer was,
whatever became of the request -- answered, refused or raised.

**A request's id is on everything it caused.** It is bound to the request's
fibre, so a line your code logs -- or the database driver, or a call to
another server -- carries it without being handed it, and so does work the
request forks. One search finds all of it. A trace id rides beside it,
joined from the caller's `traceparent` where one came.

**Pretty on a terminal, JSON everywhere else.** The keys are the ones
Datadog and an OpenTelemetry Collector read without a mapping, so the JSON
goes to a collector as it is.

**Built on [logs](https://erratique.ch/software/logs).** A library that logs
through it lands in the same shape, and your own lines are ordinary `Logs`
calls, each from a source of its own whose level can be set alone.

**Nothing is read behind your back, and a secret has no level.** The
framework reads no environment variable -- the application hands it the
levels and the format -- and it never logs a header value, a body, a query
string or a statement's parameters, at any level.

## Your own lines

A source per part of the application, and a line with a field of its own:

```ocaml
--8<-- "logging.ml:line"
```

The levels and the format, from wherever the application keeps its
settings -- here two environment variables:

```ocaml
--8<-- "logging.ml:setup"
```

```sh
$ APP_LOG='info,shop.billing=debug' APP_LOG_FORMAT=pretty dune exec ./bin/main.exe
$ curl localhost:8080/charge/500
```

```
10:11:29.978 info  shop.billing [hdy8ya7tp4mx] charged  shop.pence=500
10:11:29.979 info  spindle.http [hdy8ya7tp4mx] GET /charge/500 200  http.request.method=GET  url.path=/charge/500  http.response.status_code=200  duration=306292  http.response.body.size=8  http.route=/charge/{pence}
```

The application's line carries the request's id, `[hdy8ya7tp4mx]`, without
being handed it. As JSON, an access line is what a collector reads:

```json
{"timestamp":"2026-10-01T09:11:03.331Z","level":"info","logger.name":"spindle.http","message":"GET / 200","request_id":"cm5nxptpka21","trace_id":"5c7a41812d84b2389ac406cb04adbb31","span_id":"23583efedca0804f","http.request.method":"GET","url.path":"/","http.response.status_code":200,"duration":14875,"http.response.body.size":20,"http.route":"/"}
```

A level or a format that cannot be read is a sentence, and the program stops
on it:

```sh
$ APP_LOG='info,shop=loud' dune exec ./bin/main.exe
"loud" is not a log level
```

??? example "The whole program"

    ```ocaml
    --8<-- "logging.ml"
    ```

## What a line carries

- **The request id follows the work.** It is a fibre-local binding, so every
  fibre a request forks inherits it (a confirmation mailed after an order
  logs under the order that caused it), and `Spindle.Log.carry` takes it, with the request's trace
  and span, onto a fiber of another domain or a systhread -- `Background`
  does so for work it posts across. It is taken from `X-Request-Id` only
  from a trusted proxy.
- **So does its trace, across servers.** A request joins the W3C
  `traceparent` its caller sent, from anyone, since it is a correlation and
  never a credential, and begins a trace for one that is absent, repeated or
  not the specification's shape; it is a span of its own either way. Every
  line carries `trace_id` and `span_id`, which Datadog and a Collector link to
  the trace as they are, and every call `Spindle_client` makes for the
  request sends the trace on as a span of the call's own, unless the caller
  named a `traceparent` itself -- so a server built on Spindle that it calls
  logs under the same trace. The caller's `tracestate` goes on beside it, as
  it came, where it is no longer than W3C's 512 characters. Recording the
  spans is [Spans](#spans).
- **The keys are the collectors' own.** A line's `timestamp`, `level`,
  `message` and `logger.name` are the names Datadog and an OpenTelemetry
  Collector read without a mapping, and a request's fields are
  OpenTelemetry's HTTP attributes (`http.route`, `url.path`, …), flat keys
  with dots in them. `duration` is in nanoseconds, the unit a collector
  reads it in. A field of the framework's own is under `spindle.`
  (`spindle.refusal.code`), and an application's field is best under a
  prefix of its own, since `status`, `source`, `host` and `service`
  are a collector's to read.
- **A failure says what it was and where.** A handler's raise, a background
  job's, a stream's and a broken connection's are each logged with
  `Spindle.Log.raised`'s fields -- `error.kind`, `error.message` and
  `error.stack` -- which an error tracker groups by; `Log.setup` turns on
  backtraces so the stack is there. A refusal's detail line carries its
  route and code as fields beside them. An application's own catch-all
  takes the backtrace first thing and logs the same fields.
- **Levels mean one thing each**: `error` our bug, `warn` handled but degraded,
  `info` what happened (the access log), `debug` how. A route something
  asks every few seconds says so with `Meta.access` -- the probes set
  `Debug` -- so its lines are there when asked for and bury nothing.
- **A secret has no level.** The framework logs no header value, no body, no
  query string (a callback carries its `code` there), a statement's text but
  never its parameters. The sources that log wire bytes (TLS tracing)
  stay at `warn` whatever the everything-level says; only naming one raises it.
  Nor is any of it a span's attribute.

## Spans

```ocaml
Spindle_client.run env @@ fun client ->
Spindle_client.Otlp.run ~clock:(Eio.Stdenv.clock env)
  ~endpoint:"http://collector:4318" ~service:"shop" client
@@ fun trace -> Spindle.serve env ~trace routes

Spindle.Trace.span "price the order" (fun () -> price order)
```

With `~trace`, a request is a span, and so is what it does: the trace a
line's `trace_id` names is there in a collector, a span per part.

- **What is recorded**: the request, a `Server` span named by its method
  and route -- `GET /users/{id}`, the method alone where no route answered,
  and `HTTP` for a method not HTTP's own -- with the access line's fields,
  failed by a `5xx`; each `Spindle_client.call` and `stream`, a `Client`
  span named by its method whose id is the `traceparent` it sends, so the
  server it reaches is its child, failed by a `4xx` or `5xx` or by a call
  that did not arrive; each statement a `Spindle_postgres` connection runs,
  a `Client` span named `postgresql` with its text; and the application's
  own, `Spindle.Trace.span`, a child of whatever the fiber is in, whose
  raise is its status by constructor and passes. A span's start is the
  wall clock's and its length the monotonic clock's.
- **A trace is whole or absent.** One begun here is kept at the
  exporter's `?ratio` (every one); one joined is kept exactly when the
  caller's `traceparent` says the caller kept it, and says so onward.
  Outside a kept trace every span above is a lookup that finds nothing to
  record, and without `~trace` nothing is ever kept.
- **The type is `spindle_http`'s**, `Spindle_http.Trace` (and
  `Spindle.Trace`), where a request's context already is, so the server, the
  client and the database record into one trace and a server takes an
  exporter without linking the client. `Spindle_http.Trace.exporter` makes
  one from a function handed each span as it ends, on whichever domain ended
  it; `Trace.within`, `current`, `rename`, `add` and `fail` are what a span
  named at its end is recorded with, as the server's is.
- **The exporter is OTLP over HTTP, as JSON**, which a Collector reads at
  `/v1/traces` with no protocol buffers: `Spindle_client.Otlp.run`, an
  exporter for as long as its function runs, one fiber sending every five
  seconds or as soon as 512 spans wait, and what is left when the function
  returns. At most 2048 wait; a span past them, and a batch the collector
  refused or never answered, is dropped and counted in a `warn` line. It is
  made where the program starts, where no request is, so its own posts are
  in no trace and record nothing.

Next: [static files](static-files.md).
