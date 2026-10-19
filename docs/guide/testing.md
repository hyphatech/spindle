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
  Alcotest.(check int) "status" 200 (Spindle_http.Status.to_int r.status);
  Alcotest.(check string) "body" "hi" r.body;
  Alcotest.(check (option string))
    "type" (Some "text/plain; charset=utf-8")
    (Spindle.Test.header r "content-type")
```

- `Test.app` takes `App.make`'s arguments. It raises `Invalid_argument` for a
  route table `App.make` refuses, and for a `Static.directory` or
  `Files.directory` route: load the files with `Static.load` and serve them
  with `Static.route`, or serve a directory the test opened with
  `Files.route`, instead.
- `Test.app ~resources` supplies the
  [resources](../tutorial/dependencies.md#resources) the routes read, as the
  server's `~resources` does: a test's own pool, say,
  `Spindle.Test.app ~resources:[ Spindle.Dep.resource db test_pool ] routes`.
  It needs only those the routes it calls read; calling one that reads a
  resource it was not given raises `Invalid_argument`, naming it.
- `Test.app ~mono_clock` is the clock its
  [rate limits](rate-limits.md) are timed on: by default one that never
  moves. Give it `Eio_mock.Clock.Mono.make ()` and move it with
  `Eio_mock.Clock.Mono.set_time` to wait one out. Each app counts its own,
  so one test's calls never count against another's.
- `Test.call app meth target` takes `?now` (a `Ptime.t`, default `Ptime.epoch`),
  `?peer` (default `127.0.0.1`), `?headers` and `?body`.
- To test what a route sees behind a proxy, pass `~proxied:true`: the peer
  is then a proxy the server trusts, and `~proxy_header` says which
  forwarding header it writes. `~version:Spindle_http.Head.Http_1_0`
  sends the request as HTTP/1.0.
- The answer's status and headers are exactly what the server would write,
  cookies included, minus `connection`. A stream is run to its end.
- `r.status` is a `Spindle_http.Status.t`, as every status in the API is,
  in its one spelling: match on `` `Conflict ``, never `` `Code 409 ``, or
  compare its `Status.to_int`.
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
Here, three events of the [count stream](sse.md):

```ocaml
let test_count () =
  Eio_main.run @@ fun env ->
  let app =
    Spindle.Test.app
      ~resources:[ Spindle.Dep.resource clock (Eio.Stdenv.mono_clock env) ]
      routes
  in
  let seen = ref [] in
  match
    Spindle.Test.events app "/count" (fun e ->
        seen := e.data :: !seen;
        if List.length !seen = 3 then `Stop else `Continue)
  with
  | Ok () -> Alcotest.(check (list string)) "three" [ "1"; "2"; "3" ] (List.rev !seen)
  | Error r -> Alcotest.failf "no stream: %d" (Spindle_http.Status.to_int r.status)
```

Each event has its `name`, `data`, `id` and `retry_ms`, as a client reads
them.
`` `Stop `` is the client leaving: the route's next `send` is `Error Gone`,
and `Spindle.client_gone` is resolved.
`Error r` is the answer when the route did not stream.

## Testing WebSockets and real connections

- `Test.websocket app protocol target f` opens a socket to the route and runs
  `f` on the client's end; see [WebSockets](websockets.md).
- To test over a real socket, listen on a port of your own and serve the app
  with `Spindle.Server.serve_on`, which runs the same loop as
  `Spindle.Server.run`.
