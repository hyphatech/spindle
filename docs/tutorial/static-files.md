# Static files

Serve a directory beside your API: a built front end, its scripts and
stylesheets, a favicon. One route does it:

```ocaml
Spindle.Static.directory "dist"
```

That is all a folder needs. Use `Static` for files your build made, which
are read once when the server starts; for files that change while it runs
-- uploads, reports -- use [`Files`](#files-that-change-at-run-time).

## Serving a directory

```ocaml
--8<-- "static.ml:app"
```

`"public"` is a folder next to where you start the program. The example's is
`examples/public`, so start it from `examples/` and ask for a file:

```console
$ cd examples && dune exec ./static.exe
$ curl -I localhost:8080/style.css
HTTP/1.1 200 OK
content-type: text/css; charset=utf-8
accept-ranges: bytes
etag: "4e3597b273bb16778f1093c5780a9fe2"
cache-control: no-cache
x-content-type-options: nosniff
content-length: 88
...
```

`/` is the directory's `index.html`, and a path with no file is the
framework's `404`.

- **The directory is read into memory once, when the server starts.** A
  request is a lookup among those files, never a path on disk, so `../`
  reaches nothing. A file you change afterwards is served after a restart.
- **A directory that cannot be read stops the server**: it logs why and
  exits 1, instead of answering `404` to everything.
- **It is a route like any other**, over the rest of the path, so it goes in
  the same list as your API and every other route is matched first.
- **Every file carries an `etag`**, so a browser revalidates cheaply
  (`304`), and one `Range` is answered with `206`.
- **Every file carries `X-Content-Type-Options: nosniff`**, so a browser
  takes the type it is given and never guesses one from the bytes.
- **A precompressed copy is served when the browser accepts it.** Beside
  `app.js`, an `app.js.br`, `app.js.zst` or `app.js.gz` your build made is
  sent with `Content-Encoding` and `Vary: Accept-Encoding`. See
  [Compression](../guide/compression.md).
- **Names that start with a dot are skipped**, at any depth, so `.env` and
  `.git` are never served. The one exception is `.well-known` at the root,
  which belongs to the site (RFC 8615). `~dotfiles:true` serves them all.

## Static files beside an API

A built front end at the root, beside the API, with a page of its own for
what is not there:

```ocaml
let routes = api @ [ Spindle.Static.directory ~not_found:"/404.html" "dist" ]

let () = Eio_main.run @@ fun env -> Spindle.serve env routes
```

The options of `Static.directory`. The files and prefixes they name are
request paths, starting with `/` (`"/404.html"`, not `"404.html"`); a file
that is not in the directory stops the server at start:

- `~not_found` -- the file answered, with a `404`, for a path with no file.
- `~shell:(file, prefixes)` -- answers every path under the prefixes with one
  document and a `200`, for client-side pages whose ids are made at run time:
  `~shell:("/app/index.html", [ "/orders/" ])`. A prefix ends in `/`, so
  `/ordersheet` is not under `/orders/`.
- `~index` -- the file a directory answers with, `"index.html"` unless told.
- `~at` -- serve under a prefix instead of the root:
  `~at:Path.(s "static")`.
- `~types` -- add content types by extension:
  `[ (".wasm", "application/wasm") ]`. An unknown extension is served as
  bytes.

## Keeping assets a year

Every file is served `no-cache`: a browser keeps its copy and asks again
each time, and is answered `304` while the file is the same. That is right
for any file, and you need nothing more.

A front-end build names its scripts and stylesheets by a hash of what is in
them -- Vite's `assets/index-3f2a9c.js`, Astro's `_astro/` -- so a new
version is a new name. Those a browser can keep without asking. Say so for
the whole app, apart from what serves them:

```ocaml
Spindle.serve env
  ~middleware:[ Spindle.Cache.forever ~under:[ "/assets/" ] ]
  (api @ [ Spindle.Static.directory "dist" ])
```

`Cache.forever` keeps every successful `GET` under those prefixes a year,
whichever route answered it, and never a failure. Leave it out and nothing
is ever stale; put a prefix in it only when every name under it changes with
its bytes. Your `index.html` never goes in it: it is how a browser finds the
new names.

## Static files in a test

`Spindle.Test.app` refuses `Static.directory`, which reads its files when a
real server starts. In a test, load the directory yourself and serve it with
`Static.route`:

```ocaml
match Spindle.Static.load Eio.Path.(Eio.Stdenv.cwd env / "public") with
| Ok files -> Spindle.Test.app (routes @ [ Spindle.Static.route files ])
| Error e -> Alcotest.fail e
```

## Files that change at run time

For files that change while the server runs -- uploads, generated reports --
use `Spindle.Files`, which opens the file when the request arrives and
streams it:

```ocaml
Spindle.Files.directory ~at:Path.(s "uploads") ~download:true "var/uploads"
```

- **It never leaves its directory.** A segment that is `..`, starts with a
  dot, or holds a `/` or `\` is `404` before anything is opened, and a
  symlink out of the directory is refused by the operating system.
- **Nothing lists a directory**: one is `404`, or its `~index` where you name
  one.
- **An upload never runs as your site.** A file a browser would open as a
  page of your origin -- HTML, SVG, any XML -- is sent as an attachment and
  carries `Content-Security-Policy: sandbox`, so an uploaded `x.html` is
  downloaded rather than run beside your cookies. `~inline_active:true` shows
  one in the browser instead, still sandboxed: with no origin of its own and
  none of its script run.
- `~download:true` sends each file as an attachment with its name;
  `~dotfiles:true` serves names that start with a dot.
- Answers carry an `etag`, `Last-Modified` and `nosniff`, and answer
  conditional requests and one `Range`, as `Static` does.
- **Replace a file by writing it elsewhere and renaming it over the old
  one.** A file rewritten in place, at the same size within the clock's tick,
  keeps its `etag`.

`Spindle.Test.app` refuses `Files.directory` too. `Spindle.Files.route` takes
the same options over a directory you already hold as an `Eio.Path.t`, so a
test can serve one of its own:
`Spindle.Files.route Eio.Path.(Eio.Stdenv.cwd env / "uploads")`.

Next: [database](database.md).
