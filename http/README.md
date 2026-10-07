# spindle_http — HTTP as both ends speak it

The part of Spindle that a server and a client share: what an HTTP/1.1
message is -- a head read off a connection, where a body ends, and a message
written -- and what is spoken after one, WebSockets and the JSON they carry;
and what a line is logged with and a fiber runs under, so that a call made
while a request is answered logs under that request. `spindle` builds a
server on it and `spindle_client` a client, and the client depends on it
alone: a program that calls other servers links no framework.

It holds no socket, applies no limit it is not given and makes no decision
about a connection -- whether to keep one, how long to wait, what to answer
-- because those are the server's or the client's, and a message is the
same whoever reads it.

Each module's `.mli` is the reference.

| Module | What it is |
|---|---|
| `Status`, `Meth` | the statuses and methods; `Spindle.Status` and `Spindle.Meth` are these |
| `Field` | the one field grammar: tokens, a field line split and checked, a list field's elements -- not split inside a quoted string -- a value quoted where it must be, a field found by name |
| `Media_type` | a media type (RFC 9110 §8.3.1): a type, a subtype, parameters |
| `Accept` | content negotiation (§12): `Accept`'s ranges and the weighted token lists, and choosing among a route's offers |
| `Auth` | credentials and challenges (§11): a scheme compared without case, then a token68 or parameters |
| `Cache_control` | `Cache-Control`'s directives (RFC 9111 §5.2), and delta-seconds read as §1.2.2 has them |
| `Date` | an HTTP-date read (§5.6.7): the IMF-fixdate and the two obsolete forms a recipient accepts; `Write.date` writes one |
| `Etag` | entity tags (§8.8.3), compared strongly and weakly, and the `*` or list `If-Match` and `If-None-Match` hold |
| `Range` | byte ranges (§14): a request's `Range`, what one asks of a length, and a `Content-Range` |
| `Event_stream` | Server-Sent Events as the HTML standard writes and reads a `text/event-stream`: an event spelled, and a stream read a piece at a time into events |
| `Multipart` | `multipart/form-data` (RFC 7578, over RFC 2046's boundaries), read a part at a time from a pull function and written as a browser writes one |
| `Urlencoded` | `application/x-www-form-urlencoded`, as the WHATWG URL standard reads and writes it: a form's fields |
| `Forwarded` | the proxies in `Forwarded` (RFC 7239) |
| `Structured` | RFC 9651's Structured Fields: items, lists and dictionaries, both ways |
| `Head` | a head read off a connection: `Head.Request` a request's, with its target's form and the host it is for, and `Head.Response` a response's |
| `Framing` | where a body ends, decided from a request's head or from a response's and the method it answers, and a reader for it |
| `Write` | a start line and fields, checked whole before any byte is written, and a body's chunks |
| `Connection` | a connection once a protocol spoken after HTTP has it: its reader and writer, a clock, a send limit, and whether this end is stopping |
| `Websocket` | RFC 6455, served and called in one model; `Spindle.Websocket` is this |
| `Log` | the framework's source, a line's structured fields, a caught exception as fields, and the request a fiber runs for; `Spindle.Log` adds the reporter |
| `Trace` | spans, under the trace `Log` carries: what one is, an exporter a server, a client and a database record into, and a span begun around work; `Spindle.Trace` is this |
| `Local` | the switch of the domain a fiber runs on; `Spindle.Local` is this |

## How it reads

**Strictly, and in one direction.** A head RFC 9112 forbids is refused, never
repaired -- but for the one repair it requires of a client, below: a server behind a proxy is one of two readers of every byte, and
two readers that repair a malformed message differently disagree about where
it ends -- which is how one request becomes two. Where the RFC lets a
recipient be lenient and leniency cannot be read two ways (a line ending in a
bare LF, an empty line before a request) it is; everywhere else, the stricter
reading is taken.

**Two readers over one field grammar.** `Head.Request` is what a server
reads and `Head.Response` what a client reads, and they differ exactly where
RFC 9112 asks different things of the two ends: an obsolete folded line is
refused in a request and joined onto its field in a response (§5.2), an
empty line is skipped before a request line and not before a status line,
and a response alone may have a body that ends with its connection
(`Framing.Until_close`). Everything else -- tokens, a field line, a list's
elements -- is `Field`'s, once, so what one reader refuses the other cannot
let through. They are two functions rather than one with flags, because a
flag is a combination nobody meant waiting to be passed.

Where a response could be read two ways, the stricter reading is taken here
too: both framings at once, a transfer coding other than `chunked` -- which
nothing here decodes, and which a server may not send unasked -- and a head
cut short are errors, not guesses.

**Direct style, over any flow.** A reader takes an `Eio.Buf_read.t`, so it is
fed from a socket in production and from a flow that hands it chosen pieces
in a test. What the direct style costs is that a state the protocol has and
the code lacks is invisible -- nothing in its shape says "a head that is
complete but wrong" is a case somebody must write. The compensating control
is the conformance table.

**Every function answers a `result`.** A reader raises inside its own module
to leave a line it cannot read, and never across the interface.

## Field values

A header's value is read as far as its own structure only by the module
for that structure, each written with Angstrom as its standard's ABNF is --
`sep_by (ows *> char ',' <* ows) member` beside RFC 9651's list rule -- so
a parser is checked against its section by reading it, and a failure is a
value. The pieces every structure shares, RFC 9110 §5.6's tokens, quoted
strings, parameters and lists, are one private grammar. `Buf_read` stays
what reads a message off a socket, which is a stream with limits and
deadlines; a field value is a string already in hand.

A parser is strict as the head's reader is: whitespace where the grammar
has none, a parameter given twice where it may be once, a weight with a
fourth decimal, are refused rather than guessed at. An error says what the
value is not and quotes nothing of it, since the value may be a
credential. A structure a server writes -- a media type, a challenge,
`Cache-Control`, a Structured Field -- has a printer its parser reads back
as itself, and the printer refuses, as an `Error`, what the parser would
not. A weight, and an RFC 9651 decimal, is thousandths: both standards
allow three decimals, so every one is exact and no float is compared.

## The conformance table

`test/test_http_rfc.ml` has one row per requirement of RFC 9112, and of the
parts of RFC 9110 that bind a message's handling, that Spindle meets, named
by its section -- `9112 §6.1: Transfer-Encoding beside Content-Length is
refused`. A row is bytes and the verdict they are owed: read as a head, refused
with a status, framed, or answered by the whole server over a socket. A
response row is read as a client reads it, owed to the method it answers,
and a client row is `spindle_client` calling a scripted server of the
suite's own -- over TLS too, with a certificate the suite makes -- which
answers each request with the row's bytes and reports what the client sent,
how many connections it opened and how it closed them. Every row is read
whole and a byte at a time, and again at splits a generator chooses, since
correctness must not depend on where a socket's reads fell.
The published request-smuggling attacks -- CL.TE, TE.CL and TE.TE with each
known obfuscation, and lengths and chunk sizes written every way a reader
might misread -- are rows of their own, each owed a refusal and a close or one
answer and no other.

Beside the rows, four properties over generated and mutated messages,
requests and responses both: writing then reading is the identity; read
boundaries change nothing; no input crashes, hangs or reads past a limit;
and a random sequence of requests on one connection -- bodies read, left
unread, too large and refused -- is answered one response each, in order.

The field values are rows of their own, a value and what it must read as
or that it is refused: RFC 9110 §5.6, §8.3.1, §11 and §12, RFC 9111 §5.2
and RFC 7239. RFC 9651 is its published suite -- httpwg's
structured-field-tests, kept in `test/structured-field-tests/` at a
revision named there, with its licence -- which `test_structured` runs
whole: every record read and serialised back, those that must fail among
them.

And a referee: httpun's parser reads every generated and mutated head,
request and response, beside this one. Two readers disagreeing is the danger all of this guards against,
so disagreement is what is measured; every place this reader differs on
purpose is listed in the suite with its reason and the side that refuses,
and any other difference fails it.
