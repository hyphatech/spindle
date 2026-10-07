# Static files

Most applications serve files beside their API: a built front end, its
scripts and stylesheets, a favicon. Serving files is where a server is most
often tricked -- a `../` that walks out of the directory, a symlink that
points elsewhere -- and where caching goes subtly wrong.

## How it works

**The directory is read once, when the server starts.** `Spindle.Static`
loads every file into memory, and a request is a lookup among what was
there. Nothing maps a URL onto the filesystem, so a traversal has nothing to
traverse; a file changed afterwards is served after a restart.

**A server that cannot read its directory does not start.** It says why
and exits, rather than answer `404` to everything while looking healthy.

**It is a route like any other**, over the rest of the path, so it goes in
the same list as the API and every endpoint is asked first.

**Caching is all or nothing.** A file under an `~immutable` prefix -- hashed
assets -- is cached for a year, every other file not at all, and every file
carries a strong entity tag of its contents, so a browser asks again cheaply
and never shows a stale page with new assets.

Files that change while the server runs -- uploads, generated reports -- are
`Spindle.Files`, which opens each one as it is asked for, and never outside
its directory; it is below.

## A directory, served

```ocaml
--8<-- "static.ml:app"
```

```sh
$ curl -I localhost:8080/style.css
HTTP/1.1 200 OK
content-type: text/css; charset=utf-8
accept-ranges: bytes
etag: "4e3597b273bb16778f1093c5780a9fe2"
cache-control: no-cache
content-length: 88
```

`/` is the directory's `index.html`, and a path that was not there is the
framework's `404`.

## Beside an API

A built front end at the root, its hashed assets cached for a year and a
page of its own for what is not there:

```ocaml
let routes =
  api @ [ Spindle.Static.directory ~not_found:"/404.html" ~immutable:[ "/_astro/" ] "dist" ]

let () = Eio_main.run @@ fun env -> Spindle.serve env routes
```

`~at` puts it under a prefix instead of the root, and `~shell` answers a
path under a prefix with one document and a `200`, for pages whose ids are
made at run time.

## What it promises

**A server that cannot read its directory does not start**: `Spindle.serve`
says why in the log and exits 1, since a server missing what it was written
to serve answers `404` to everything and looks healthy. `App.start` is what
it calls, and a program on `Server.run` calls it first. Underneath, `load`
reads a directory now and answers a result, and `route` serves what it read
-- for a test, which has no filesystem to start from and is refused a
`directory`, and for a program whose site may be absent, as a checkout
before its first build.

Nothing maps a request onto the filesystem: a request is a lookup among the
files that were there, so a traversal has nothing to traverse, and a changed
file needs a restart. A directory is its `index.html`; a path under a
`~shell` prefix is the shell document with a `200`, for pages whose ids are
made at run time; anything else is the `~not_found` document with a `404`,
or the framework's `404`. Content types come from a table of the extensions
a site ships, added to with `~types`, and an unknown one is bytes. A file
under an `~immutable` prefix is cached for a year and every other one not at
all, with nothing in between, because a middle value for a document is how a
stale page outlives its assets. Every file carries a strong entity tag, its
digest, and answers its preconditions and one `Range` as `Files` does, below.

The route takes only the paths no other route names, so every endpoint is
asked first, and another method under it is `405`. A trailing slash is the
app's `~trailing_slash` policy, which with `Redirect` sends `/about/` to
`/about`.

## Files from disk

`Spindle.Files` serves a directory that changes while the server runs --
uploads, generated reports -- opening the file a request names when it
arrives:

```ocaml
Spindle.Files.directory ~at:Path.(s "uploads") ~download:true "var/uploads"
```

**It never leaves its directory, twice over.** A segment that is empty, `.`
or `..`, begins with a dot (unless `~dotfiles:true`), or holds `/`, `\` or
NUL is `404` before anything is opened, and every file is opened beneath
the directory as an Eio subtree, so a symlink out of it is refused by the
operating system as well. Nothing lists a directory: one is `404`, or its
`~index` where one is named. The directory is checked when the server
starts, as `Static`'s is, and `Files.route` serves one the program already
holds.

**An answer is streamed** in 64 KiB reads with its length known --
`Response.stream ~length`, which the server frames with `Content-Length`
and whose connection it closes behind a body that sends another number of
bytes -- a strong entity tag of its size and its time to the nanosecond, and
`Last-Modified`. Its preconditions are answered in RFC 9110's order:
`If-Match` and `If-Unmodified-Since` with `412`, `If-None-Match` and
`If-Modified-Since` with `304`. One `Range` is `206` with `Content-Range`,
one past the end `416`, and several, another unit, or an `If-Range` naming
the file as it no longer is are answered whole. A file replaced between its
answer's head and its body sends nothing, and its connection closes, rather
than send another file's bytes under this one's length. Write one by writing
it elsewhere and renaming it over the old: a file rewritten in place at the
same size within the clock's tick keeps its tag. `~download:true` names the
file in `Content-Disposition: attachment`, with `filename*` for a name that is
not plain ASCII. Content types are `Static`'s table.

Next: [a database](database.md).
