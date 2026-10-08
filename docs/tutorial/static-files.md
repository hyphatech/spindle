# Static files

Serve a directory beside your API: a built front end, its scripts and
stylesheets, a favicon.

## Serving a directory

```ocaml
--8<-- "static.ml:app"
```

Run it from `examples/`, since `"public"` is relative to the working
directory:

```sh
curl -I localhost:8080/style.css
```

```text
HTTP/1.1 200 OK
content-type: text/css; charset=utf-8
accept-ranges: bytes
etag: "4e3597b273bb16778f1093c5780a9fe2"
cache-control: no-cache
content-length: 88
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

## Static files beside an API

A built front end at the root, its hashed assets cached for a year, and a
page of its own for what is not there:

```ocaml
let routes =
  api
  @ [
      Spindle.Static.directory ~not_found:"/404.html" ~immutable:[ "/_astro/" ]
        "dist";
    ]

let () = Eio_main.run @@ fun env -> Spindle.serve env routes
```

The options of `Static.directory`:

- `~immutable` -- prefixes whose files are cached for a year. Every other
  file is `no-cache`; there is nothing in between, so a page never outlives
  the assets it names.
- `~not_found` -- the file answered, with a `404`, for a path with no file.
- `~shell:(file, prefixes)` -- answers every path under the prefixes with one
  document and a `200`, for client-side pages whose ids are made at run time.
- `~index` -- the file a directory answers with, `"index.html"` unless told.
- `~at` -- serve under a prefix instead of the root:
  `~at:Path.(s "static")`.
- `~types` -- add content types by extension:
  `[ (".wasm", "application/wasm") ]`. An unknown extension is served as
  bytes.

In a test, which has no filesystem, load the directory with
`Static.load` and serve it with `Static.route`.

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
- `~download:true` sends each file as an attachment with its name;
  `~dotfiles:true` serves names that start with a dot.
- Answers carry an `etag` and `Last-Modified`, and answer conditional
  requests and one `Range`, as `Static` does.
- **Replace a file by writing it elsewhere and renaming it over the old
  one.** A file rewritten in place, at the same size within the clock's tick,
  keeps its `etag`.

Next: [database](database.md).
