# Testing

`Spindle.Test` calls your app in-process: no socket, no port, and a clock the
test sets. It works with any test library; these examples use Alcotest.

```ocaml
let echo =
  Spindle.post
    Spindle.Path.(s "echo")
    Spindle.Returns.text
    (let+ body = Spindle.body in
     Ok body)

let test_echo () =
  let app = Spindle.Test.app [ echo ] in
  let r = Spindle.Test.call app `POST "/echo" ~body:"hi" in
  Alcotest.(check int) "status" 200 r.status;
  Alcotest.(check string) "body" "hi" r.body;
  Alcotest.(check (option string))
    "type" (Some "text/plain; charset=utf-8")
    (Spindle.Test.header r "content-type")
```

- `Test.app` takes `App.make`'s arguments. It raises `Invalid_argument` for a
  route table `App.make` refuses, and for a `Static.directory` route: load
  the files with `Static.load` and serve them with `Static.route` instead.
- `Test.call app meth target` takes `?now` (epoch milliseconds, default 0),
  `?peer` (default `127.0.0.1`), `?headers` and `?body`.
- The answer's status and headers are exactly what the server would write,
  cookies included, minus `connection`. A stream is run to its end.
- A refusal with a code the route does not declare, or a status its route
  does not list, raises `Invalid_argument`: the server would only log that
  bug, the test fails on it.

## Testing cookies and sign-in

`Test.browser` keeps the cookies the app sets, as a browser does, and sends
them on later calls:

```ocaml
let b = Spindle.Test.browser app in
let _ = Spindle.Test.Browser.call b `POST "/sign-in" ~body in
let me = Spindle.Test.Browser.call b `GET "/me" in ...
```

A cookie is dropped when the app clears it or when its age is past a later
call's `~now`. `Test.Browser.cookies b` lists what it holds.

## Testing event streams

`Test.events` hands each event to your function until it answers `` `Stop ``.
Here, three events of the [count stream](streams.md):

```ocaml
let test_count () =
  Eio_main.run @@ fun env ->
  let app = Spindle.Test.app (routes ~clock:(Eio.Stdenv.clock env)) in
  let seen = ref [] in
  match
    Spindle.Test.events app "/count" (fun e ->
        seen := e.data :: !seen;
        if List.length !seen = 3 then `Stop else `Continue)
  with
  | Ok () -> Alcotest.(check (list string)) "three" [ "1"; "2"; "3" ] (List.rev !seen)
  | Error r -> Alcotest.failf "no stream: %d" r.status
```

Each event has its `name`, `data` and `id`, as a client reads them.
`` `Stop `` is the client leaving: the route's next `send` is `Error Gone`.
`Error r` is the answer when the route did not stream.

## Testing WebSockets and real connections

- `Test.websocket app protocol target f` opens a socket to the route and runs
  `f` on the client's end; see [WebSockets](websockets.md).
- To test over a real socket, listen on a port of your own and serve the app
  with `Spindle.Server.serve_on`, which runs the same loop as
  `Spindle.Server.run`.
