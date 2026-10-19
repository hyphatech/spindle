# Rate limits

Limit how often a client may call a route. A limit is a dependency: you list
it in the route, and the route's OpenAPI document shows its `429`.

```ocaml
let sign_ins = Spindle.Rate.create ~limit:10 ~per:Mtime.Span.min ()

let sign_in =
  Spindle.post
    Spindle.Path.(s "sign-in")
    Spindle.Returns.text
    (let+ () = Spindle.Rate.limit sign_ins ~key:Spindle.client in
     Ok "in")

let () = Eio_main.run @@ fun env -> Spindle.serve env [ sign_in ]
```

Ten sign-ins a minute per client pass; the eleventh is refused:

```console
$ curl -i -X POST localhost:8080/sign-in
HTTP/1.1 429 Too Many Requests
content-type: application/json
retry-after: 6
...

{"error":"rate_limited","message":"That was asked too often. Please try again in a moment."}
```

- `Rate.create ~limit ~per ?burst ()` allows `limit` calls every `per`, an
  `Mtime.Span.t`, and up to `burst` (default: `limit`) at once. Make it
  once, at the top level, beside the routes that read it. A `limit` or
  `burst` below one, or a `per` shorter than `limit` nanoseconds, which
  leaves no time between two calls, raises `Invalid_argument` there.
- `~key` is what is counted: `Spindle.client` (the client's address), or any
  `string Dep.t` -- a session, a token, a path parameter. An IPv6 address is
  counted by its /64, since a client may change its address within one at
  will; an IPv4 address by itself.
- `Retry-After` is in whole seconds, at least one.
- Behind a proxy, `Spindle.client` is the address your `~trusted_proxies`
  vouch for; without them every request has the proxy's address.
- The counts are the app's, timed on the server's monotonic clock: each
  app serving the limit counts its own, and several processes each count
  their own.
- A test's app counts on a clock that never moves, so a limit refuses and
  never refills. To wait one out, give `Spindle.Test.app ~mono_clock` an
  `Eio_mock.Clock.Mono.make ()` and move it with
  `Eio_mock.Clock.Mono.set_time`. Add `eio.mock` to the test's `libraries`
  in its `dune` file.
