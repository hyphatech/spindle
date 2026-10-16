# Compression

Spindle can gzip its answers. It is off unless you turn it on, since it costs
CPU and the proxy in front of you often compresses already:

```ocaml
Spindle.serve env ~compress:Spindle.Compress.default routes
```

A client that sends `Accept-Encoding: gzip` now gets text, JSON and the like
compressed -- here, a route answering 5,000 bytes of text:

```sh
curl -i -H 'accept-encoding: gzip' localhost:8080/big
```

```text
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
vary: Accept-Encoding
content-encoding: gzip
content-length: 47
...
```

## What is compressed

`Compress.make ?min_bytes ?level ?types ()` says what is worth it;
`Compress.default` is `make ()`:

- `min_bytes`: answers smaller than this are sent as they are. Default 1024.
- `level`: deflate's level, 1 to 9. Default 6.
- `types`: media types to compress, as `type/subtype`, `type/*` or
  `type/*+suffix`. Default: text, JSON, XML, JavaScript, SVG and event
  streams.

A level outside 1 to 9, a negative `min_bytes`, or a `types` entry that is
none of the three forms raises `Invalid_argument` where it is made.

An answer is left alone when it sets its own `Content-Encoding`, says
`Cache-Control: no-transform`, or is a range. Every answer of a listed type
says `Vary: Accept-Encoding`, compressed or not, and so does a `304`.

## Revalidating a compressed answer

A compressed answer is another representation, so its `ETag` is the route's
with the coding marked inside the quotes: `"v1"` becomes `"v1-gzip"`. A client
sends that tag back, and it works as the route's own:

- **Your route sees its own tags.** `If-Match` and `If-None-Match` reach it
  with the mark taken off, so a route that compares them -- `Static`,
  `Files`, or yours -- answers `304` or `412` as it would uncompressed.
  `If-None-Match` is unmarked only where the request takes gzip: a client
  holding the compressed answer that no longer takes it is answered whole.
- **A `304` repeats the tag the client holds**, `"v1-gzip"`, and the `Vary`.
  A route that sets an `ETag` and never reads `If-None-Match` is answered
  `304` for the compressed tag all the same.
- **A range is never of the compressed answer**: an `If-Range` holding the
  marked tag gets the whole answer, compressed.

**Streams** are compressed as they go: each `send` reaches the client at once,
decodable on arrival.

**Files** are never compressed as they are read. `Static` and `Files` serve a
`.br`, `.zst` or `.gz` file your build wrote beside the original instead,
when the client accepts that coding.

## Turning it off for a route

A route that puts a secret in its answer beside text the request sent -- a
CSRF token next to a search term, say -- should not be compressed, because
the compressed length can leak the secret:

```ocaml
Spindle.get ~meta:Spindle.Meta.(empty |> add Spindle.Compress.never ()) ...
```
