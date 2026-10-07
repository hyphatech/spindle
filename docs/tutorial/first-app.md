# Your first app

On this page you make a project, write a server that answers one request,
compile it and run it -- and then turn on its log to see what it is doing.
It assumes only that [Spindle is installed](../install.md).

## 1. Make the project

A project is a folder with three files in it:

```
hello/
├── dune-project
└── bin/
    ├── dune
    └── main.ml
```

Make the folders:

```sh
mkdir hello
cd hello
mkdir bin
```

Then create each file with this content.

`dune-project` tells dune that this folder is a project, and which version
of dune's language its files are written in:

```lisp title="dune-project"
(lang dune 3.16)
```

`bin/dune` says what to build there: a program named `main`, made from
`main.ml`, which uses Spindle and Eio's event loop. The last two lines let
you turn a type into JSON, which the tutorial uses from the next page on:

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

## 2. Compile and run it

From the `hello` folder:

```sh
dune build
```

This compiles the project. A mistake in the code is reported here, with its
file and line, and nothing runs until it is fixed; no output means it
worked. Then run it:

```sh
$ dune exec ./bin/main.exe
Listening on http://localhost:8080 (127.0.0.1 and [::1])
```

`dune exec` compiles first if anything changed, so after the first time it
is the one command you need. Open <http://localhost:8080> in a browser, or
ask from another terminal:

```sh
$ curl localhost:8080
Good morning, world!
```

`Ctrl-C` stops the server.

!!! tip "Rebuilding as you type"

    `dune build --watch` in a terminal of its own compiles every time you
    save, so a mistake shows up the moment you make it.

## 3. What the code says

The program has three parts, and every program in this tutorial keeps them
apart:

- **The handler**, `good_morning`: the answer. `Ok` means it succeeded --
  an `Error` would refuse the request instead.
- **The routes**: a list with one route in it. `Spindle.get` is the method,
  `Spindle.Path.root` the path `/`, and `Spindle.Returns.text` says it
  answers text. The last part says what the handler needs from the request
  -- nothing, here, so it is `Spindle.Dep.return` of the answer.
- **The server**: `Eio_main.run` starts OCaml's event loop, and
  `Spindle.serve` serves the routes in it until you stop it.

## 4. See what is going on

The server is silent. Add one line at the start of the last part, to turn
on its log:

```ocaml title="bin/main.ml" hl_lines="2"
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
```

Run it again and ask it something. Every request is now a line, with its
method, path, status, how long it took and an id of its own:

```
10:11:03.331 info  spindle.http [cm5nxptpka21] GET / 200  http.request.method=GET  url.path=/  http.response.status_code=200  duration=14875  http.response.body.size=20  http.route=/
```

The same id is in the answer's `x-request-id` header, so a request a user
reports can be found in the log. [Logging](logging.md) is the rest of it.

## What you get without writing it

Ask for something the server does not do:

```sh
$ curl -i -X DELETE localhost:8080
HTTP/1.1 405 Method Not Allowed
content-type: application/json
allow: GET, HEAD

{"error":"method_not_allowed","message":"That is not something you can do here."}
```

- A clear answer to every request it cannot serve -- here `405` with the
  methods it does take -- always in the same JSON shape: a code a program
  can check and a sentence a person can read.
- A server error never shows the user what went wrong inside; that goes to
  the log.
- Every core of the machine serving, from the first request.
- A clean stop on `Ctrl-C`, letting requests in flight finish.

To serve on another port, give `serve` one more argument:
`Spindle.serve env ~port:3000 routes`.

Next: [routes](routes.md), and an API that does more than say good morning.
