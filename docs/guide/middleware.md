# Middleware

A middleware is a function from a handler to a handler. It wraps every route
and the not-found answer, for what applies to everything: headers, a
maintenance page, timing.

## Example: counting requests

```ocaml
--8<-- "middleware.ml"
```

```sh
curl localhost:8080/
```

```text
Saw 1 request(s)!
```

```sh
curl localhost:8080/
```

```text
Saw 2 request(s)!
```

## Writing middleware

```ocaml
let security =
  Spindle.Middleware.headers
    [ ("x-content-type-options", "nosniff"); ("referrer-policy", "same-origin") ]

let closed_for_maintenance _handler _request =
  Spindle.Response.refusal (Spindle.Refusal.make closed "Back in a minute.")

(* A policy for some routes reads the matched route, never the path. *)
let limit : int Spindle.Meta.key = Spindle.Meta.key ()

let limited handler request =
  match
    Option.bind (Spindle.Route.matched request) (fun r ->
        Spindle.Meta.find limit r.meta)
  with
  | Some n when over n request ->
      Spindle.Response.refusal (Spindle.Refusal.make slow_down "Too fast.")
  | Some _ | None -> handler request

let () =
  Eio_main.run @@ fun env ->
  Spindle.serve env ~middleware:[ security; limited ]
    ~codes:[ closed; slow_down ] routes
```

- **Order:** `[a; b]` is `a (b app)`: the first listed sees the request
  first and the response last.
- **It may answer alone**, without calling the handler, and may change a
  response's status and headers (`Response.add_headers`). It cannot rewrite
  a stream's body.
- **It cannot reroute.** The request is matched before any middleware runs;
  `Route.matched request` is that route's `Route.info` (with its `Meta`), or
  `None` when no route answered. To send someone elsewhere, answer a
  redirect.
- **Declare its refusal codes** in `~codes` (on `Spindle.serve` or
  `App.make`). A code nobody declared is logged as a bug, and raises in a
  test. These codes are not written into the OpenAPI document.
- **A raise is a `500`**, as a handler's is.
- `Middleware.headers` is the one built in. It never overrides a header the
  route set itself.

What one route needs -- a session, a [rate limit](rate-limits.md) -- is not
middleware but a dependency of that route, so it shows in the route and its
document. Logging is the server's own.
