# HTTP client

`Spindle_client` calls other HTTP and HTTPS servers. It is its own library,
so a program that only calls out links no framework:

```lisp
(executable
 (name main)
 (libraries spindle.client eio_main))
```

## Making a request

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Spindle_client.run env @@ fun client ->
  match Spindle_client.call client `GET "https://example.com/" with
  | Ok { status; body; _ } -> Printf.printf "%d, %d bytes\n" status (String.length body)
  | Error e -> prerr_endline (Spindle_client.error_to_string e)
```

`Spindle_client.run env f` makes a client for as long as `f` runs and closes
its connections when `f` returns.

`call client meth url` answers `Ok` with the `status`, the `headers` (names
lower-cased) and the whole `body` -- **any status is an answer**, so a `404`
is `Ok`. `Error` is `Unreachable` (no connection, bad TLS, an unreadable
answer) or `Timed_out`. Send a body with `~body` and `~headers`:

```ocaml
match
  Spindle_client.call client ~timeout_s:10.
    ~headers:[ ("content-type", "application/json") ] ~body
    `POST "https://api.example.com/v1/things"
with
| Ok { status = 200; body; _ } -> decode body
| Ok r -> Error (Printf.sprintf "upstream answered %d" r.status)
| Error e -> Error (Spindle_client.error_to_string e)
```

## Using a client inside a server

Make it once, with `Spindle_client.create`, on the application's switch --
never a request's, since the connections it keeps outlive any one request:

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    Spindle_client.create ~sw ~net:(Eio.Stdenv.net env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) ()
  in
  Spindle.serve env (routes client)
```

`create` and `run` take the same options:

| Option | Default | |
|---|---|---|
| `~timeout_s` | 30 | each call's deadline, over the whole call; a call can name its own |
| `~max_body` | 16 MiB | the longest answer read |
| `~per_host` | 4 | idle connections kept per scheme, host and port, on each domain |
| `~idle_s` | 15 | how long an unused connection is kept |
| `~authenticator` | system trust store | what a server's certificate is checked against |

Good to know:

- Connections are reused when the answer was read to its end and neither side
  said `close`. A call never waits for a free connection; it opens its own.
  Limiting how many calls run at once is up to you.
- A request is retried only when that is safe: one that could not be written
  on a reused connection, or an idempotent one (`GET`, `HEAD`, `PUT`,
  `DELETE`, `OPTIONS`) whose reused connection closed before any answer. A
  `POST` that went out is never sent twice; it fails, and you decide.
- Each call logs one `debug` line on `spindle.client`, never its headers or
  body.

## Streaming a response

`Spindle_client.stream` hands your function the `status`, `headers` and a
`body` to read piece by piece -- a streamed model answer, or a download too
large to hold:

```ocaml
Spindle_client.stream client `GET url (fun answer ->
    let rec copy () =
      match Spindle_client.Body.read answer.body with
      | Ok (`Data piece) -> print_string piece; copy ()
      | Ok `End -> Ok ()
      | Error e -> Error e
    in
    copy ())
```

`~timeout_s` bounds the head, and `~read_timeout_s` each wait for more of the
body. To stop early, return: the connection is then closed.

## Server-Sent Events

`Spindle_client.events client url f` asks for `text/event-stream` and hands
each event (its `name`, `data`, `id` and `retry`) to `f`, which answers
`` `Continue `` or `` `Stop ``. It answers `Finished` (the server ended it) or
`Stopped`, each with the last event id, or `Refused` with the answer when it
was not an event stream. To reconnect, call it again with
`~last_event_id`.

## WebSockets and tracing

- `Spindle_client.websocket` opens a WebSocket: see
  [WebSockets](websockets.md#connecting-as-a-client).
- A call made while a request is traced is a span of its trace, and
  `Spindle_client.Otlp` sends spans to a collector: see
  [Tracing](../tutorial/logging.md#tracing).
