# Rate limits

Limit how often a client may call a route. A limit is a dependency: you list
it in the route, and the route's OpenAPI document shows its `429`.

```ocaml
let sign_in sign_ins =
  Spindle.post
    Spindle.Path.(s "sign-in")
    Spindle.Returns.text
    (let+ () = Spindle.Rate.limit sign_ins ~key:Spindle.client in
     Ok "in")

let () =
  Eio_main.run @@ fun env ->
  let sign_ins =
    Spindle.Rate.create
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~limit:10 ~per:Mtime.Span.min ()
  in
  Spindle.serve env [ sign_in sign_ins ]
```

Ten sign-ins a minute per client pass; the eleventh is refused:

```sh
curl -i -X POST localhost:8080/sign-in
```

```text
HTTP/1.1 429 Too Many Requests
content-type: application/json
retry-after: 6
...

{"error":"rate_limited","message":"That was asked too often. Please try again in a moment."}
```

- `Rate.create ~mono_clock ~limit ~per ?burst ()` allows `limit` calls
  every `per`, an `Mtime.Span.t`, and up to `burst` (default: `limit`) at
  once. Make it once, at startup, and share it between requests. A `limit`
  or `burst` below one, or a `per` shorter than `limit` nanoseconds, which
  leaves no time between two calls, raises `Invalid_argument` there.
- `~key` is what is counted: `Spindle.client` (the client's address), or any
  `string Dep.t` -- a session, a token, a path parameter. An IPv6 address is
  counted by its /64, since a client may change its address within one at
  will; an IPv4 address by itself.
- `Retry-After` is in whole seconds, at least one.
- Behind a proxy, `Spindle.client` is the address your `~trusted_proxies`
  vouch for; without them every request has the proxy's address.
- Counts live in this one process: several processes each count their own.
- In a test, pass `Eio_mock.Clock.Mono.make ()` as `~mono_clock` and move it
  with `Eio_mock.Clock.Mono.set_time`. Add `eio.mock` to the test's
  `libraries` in its `dune` file.
