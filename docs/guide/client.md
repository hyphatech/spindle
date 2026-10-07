# Calling another server

```ocaml
match
  Spindle_client.call client ~timeout_s:10.
    ~headers:[ ("content-type", "application/json") ] ~body
    `POST "https://api.example.com/v1/things"
with
| Ok { status = 200; body; _ } -> decode body
| Ok r -> Error (Printf.sprintf "upstream answered %d" r.status)
| Error e -> Error (Spindle_client.error_to_string e) (* Unreachable | Timed_out *)
```

A program whose job is calling out takes its client as `Spindle.serve`
takes its routes, from Eio's environment, for as long as a function runs:
`Spindle_client.run env @@ fun client -> ...`, every kept connection closed
when it returns. A client beside a server is made once, with
`Spindle_client.create ~sw ~net ~mono_clock ()`, on the application's
switch, and never on a request's, because a connection it keeps outlives
the call that opened it.
It keeps them **per domain**: a call borrows only what its own domain kept,
on that domain's switch, so a domain's calls never wait for another's, and a
call on a domain with neither Spindle's switch nor the client's own closes
its connection after it. Every call reads the whole body
and has a deadline over all of it. Any status is an answer. Cancellation
passes through. The request is written and the response read by
`spindle_http`, as the server's are, over TLS by `tls-eio` directly: every
1xx before the answer is skipped, a response cut short or framed two ways is
an error, and a TLS connection is ended with its closure alert.

A connection is kept after a call when the response was read to its end and
neither side said `close`, up to `?per_host` idle ones per scheme, host and
port on each domain, for `?idle_s` or a second short of the less the
server's `Keep-Alive: timeout=` said -- and not at all where it said a
second or less, since a `POST` lent in the instant the server closes it is
sent to nobody and never sent again. A call past the ones kept opens its own
rather than wait: how many calls run at once is the caller's to limit. A new
connection tries every address the host's name has, in the resolver's
order, until one connects, since the first may be an IPv6 address a machine
has no route for; each that fails is closed as it fails, never left open on
the domain's switch. While it waits, a kept connection's socket
is watched, and the server closing it or sending anything unasked retires it;
and as it is lent its socket is asked once more, so one the server has given
up on, or spoken on unasked, is never lent, however soon the next call
comes. The watch is a daemon: a connection nobody is using holds no switch,
and no process, open. A call whose
deadline passes, or that fails, closes its connection rather than return it.

A call is sent twice only where that cannot be wrong: a request that could
not be written on a reused connection goes once more on a new one, and so
does an idempotent one whose reused connection ended before a byte of the
answer. A `POST` that went out is never sent again; it fails, and the caller
decides. A connection carries one call at a time and is never pipelined,
since a pipelined request behind a `POST` that failed cannot be told sent
from unsent (RFC 9112 §9.3.2). The `debug` line each call writes on `spindle.client` says whether
its connection was new or reused.

**An answer read as it arrives** is `Spindle_client.stream`, a bracket: its
function is handed the status, the headers and the body as a reader
(`Body.read`), and the connection is kept after it only if the body was read
to its end and neither side said `close` -- so stopping early is returning.
`~timeout_s` bounds the head and `~read_timeout_s` each wait for more, never
the whole, since a stream's length is its own. **`Spindle_client.events`**
is `stream` asking for `text/event-stream`, with `Last-Event-ID` where given
one, handing each event -- its name, data, id and retry -- to a function that
answers `` `Continue `` or `` `Stop ``; it answers how the stream ended and
the last id it set, `Finished` or `Stopped`, or `Refused` with the answer
where it was no event stream, and reconnecting is the caller's loop. The
events are read by `Spindle_http.Event_stream`, which `Spindle.Event` writes
with, so both ends have one account of where an event ends, and an event is
held to the client's `max_body` as an answer is: a server that never ends a
line is an error, not a buffer without end.

**A call made in a kept trace is a span of it**, `call` and `stream` alike,
as [Spans](../tutorial/logging.md#spans) says, and `Spindle_client.Otlp` is where a server's spans
are sent.
