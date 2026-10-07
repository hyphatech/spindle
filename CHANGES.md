# Changes

## Unreleased

- `spindle`: `Codec.float` reads a number in decimal digits, with an
  optional minus sign, fraction and exponent, and refuses what
  `float_of_string` would also take but no client means, and a number too
  large for a float. It is described as `number`. Breaking: `Number` joins
  `Codec.shape`, so a match over it needs the case.

## 0.1.0 (2026-10-07)

First release.

- `spindle`: routes as values, a method and a path declared together;
  dependencies that list what a route reads and run once per request;
  typed answers and refusals from declared codes; signed and encrypted
  cookies and sessions; rate limits, CORS, an origin check, compression,
  static files read at startup and files beneath a directory; event
  streams, broadcasts and WebSockets; logging with a request's id on every
  line, metrics and traces; and the routes described as OpenAPI 3.2 and
  zod, served with Scalar's reference.
- `spindle.http`: HTTP/1.1 read and written by itself -- heads, framing,
  fields, dates, structured fields, multipart -- each requirement of RFC
  9112, RFC 9110 and RFC 6455 it meets a row of its suites.
- `spindle.client`: calling another server over HTTPS with the system's
  trust store, a kept connection per domain and a deadline per call, and a
  WebSocket client, linking no framework.
- `spindle_postgres`: a server's Postgres over rowtype's backend:
  connections bounded as a server bounds them, a pool and its probe, and a
  failure's refusal.
- `spindle_cli`: an application's command line, writing and checking its
  OpenAPI document and zod from the routes.
