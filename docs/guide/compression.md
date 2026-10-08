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
```

## What is compressed

`Compress.make ?min_bytes ?level ?types ()` says what is worth it;
`Compress.default` is `make ()`:

- `min_bytes`: answers smaller than this are sent as they are. Default 1024.
- `level`: deflate's level, 1 to 9. Default 6.
- `types`: media types to compress, as `type/subtype`, `type/*` or
  `type/*+suffix`. Default: text, JSON, XML, JavaScript, SVG and event
  streams.

An answer is left alone when it sets its own `Content-Encoding`, says
`Cache-Control: no-transform`, or is a range. Every answer of a listed type
says `Vary: Accept-Encoding`, compressed or not.

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
