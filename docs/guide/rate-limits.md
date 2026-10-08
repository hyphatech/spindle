# Rate limits

Limit how often a client may call a route. A limit is a dependency: you list
it in the route, and the route's API document shows its `429`.

```ocaml
let sign_ins = Spindle.Rate.create ~mono_clock ~limit:10 ~per_s:60. ()

let sign_in =
  Spindle.post
    Spindle.Path.(s "sign-in")
    Spindle.Returns.text
    (let+ () = Spindle.Rate.limit sign_ins ~key:Spindle.client in
     Ok "in")
```

Ten sign-ins a minute per client pass; the eleventh is refused:

```sh
curl -i -X POST localhost:8080/sign-in
```

```text
HTTP/1.1 429 Too Many Requests
content-type: application/json
retry-after: 6

{"error":"rate_limited","message":"That was asked too often. Please try again in a moment."}
```

- `Rate.create ~mono_clock ~limit ~per_s ?burst ()` allows `limit` calls
  every `per_s` seconds, and up to `burst` (default: `limit`) at once.
  Make it once, at startup, and share it between requests.
- `~key` is what is counted: `Spindle.client` (the client's address), or any
  `string Dep.t` -- a session, a token, a path parameter.
- `Retry-After` is in whole seconds, at least one.
- Behind a proxy, `Spindle.client` is the address your `~trusted_proxies`
  vouch for; without them every request has the proxy's address.
- Counts live in this one process: several processes each count their own.
- In a test, pass `Eio_mock.Clock.Mono.make ()` as `~mono_clock` and move it
  with `Eio_mock.Clock.Mono.set_time`.
