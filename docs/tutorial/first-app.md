# Your first app

Make a project, write a server that answers one request, and run it. This
assumes [Spindle is installed](../install.md).

## 1. Make the project

A project is a folder with three files:

```
hello/
├── dune-project
└── bin/
    ├── dune
    └── main.ml
```

```sh
mkdir -p hello/bin
cd hello
```

`dune-project` marks the folder as a dune project:

```lisp title="dune-project"
(lang dune 3.18)
```

`bin/dune` builds a program named `main` that uses Spindle and Eio's event
loop. The `preprocess` line turns your types into JSON, which the tutorial
uses from the next page on:

```lisp title="bin/dune"
(executable
 (name main)
 (libraries spindle eio_main)
 (preprocess
  (pps ppx_wiretype)))
```

`bin/main.ml` is the server:

```ocaml title="bin/main.ml"
--8<-- "hello.ml:app"
```

## 2. Run it

From the `hello` folder:

```sh
dune exec ./bin/main.exe
```

```text
Listening on http://localhost:8080 (127.0.0.1 and [::1])
```

`dune exec` compiles, reports any mistake with its file and line, and runs.
Open <http://localhost:8080>, or from another terminal:

```sh
curl localhost:8080
```

```text
Good morning, world!
```

`Ctrl-C` stops the server.

!!! tip "Rebuilding as you type"

    `dune build --watch` in a terminal of its own compiles on every save.

## 3. What the code says

- **The handler**, `good_morning`, is the answer. `Ok` means success; an
  `Error` would refuse the request.
- **The routes** are a list. `Spindle.get` is the method,
  `Spindle.Path.root` the path `/`, and `Spindle.Returns.text` says it
  answers text. The last argument is what the handler needs from the
  request -- nothing here, so `Spindle.Dep.return` of the answer.
- **The server**: `Eio_main.run` starts the event loop, and `Spindle.serve`
  serves the routes until you stop it.

## 4. Turn on the log

Add one line to see every request:

```ocaml title="bin/main.ml" hl_lines="2"
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
```

Every request is now a line with its method, path, status, duration and an
id:

```
10:11:03.331 info  spindle.http [cm5nxptpka21] GET / 200  http.request.method=GET  url.path=/  http.response.status_code=200  duration=14875  http.response.body.size=20  http.route=/
```

The same id is in the answer's `x-request-id` header, so a request a user
reports can be found in the log. More in [logging](logging.md).

## What you get for free

Ask for something the server does not do:

```sh
curl -i -X DELETE localhost:8080
```

```text
HTTP/1.1 405 Method Not Allowed
content-type: application/json
allow: GET, HEAD

{"error":"method_not_allowed","message":"That is not something you can do here."}
```

- Every error in one JSON shape: a code a program can check and a sentence
  a person can read. Internal errors go to the log, never to the client.
- Every CPU core serving, from the first request.
- A clean stop on `Ctrl-C`, letting requests in flight finish.

Another port is one argument: `Spindle.serve env ~port:3000 routes`.

Next: [routes](routes.md).
