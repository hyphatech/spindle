# Middleware

A middleware is a function from a handler to a handler. It wraps every route
and the not-found answer, for what applies to everything: headers, a
maintenance page, timing.

## Example: counting requests

```ocaml
--8<-- "middleware.ml"
```

```console
$ curl localhost:8080/
Saw 1 request(s)!

$ curl localhost:8080/
Saw 2 request(s)!
```

## Writing middleware

Two middlewares: one built in, and one that applies only to the routes that
ask for it.

```ocaml
open Spindle.Syntax

let security =
  Spindle.Middleware.headers
    [ ("x-content-type-options", "nosniff"); ("referrer-policy", "same-origin") ]

(* A policy for some routes: a key a route sets, read from the route the
   request matched, never from its path. *)
let noindex : bool Spindle.Meta.key = Spindle.Meta.key ()

let hide_from_search handler request =
  let response = handler request in
  match
    Option.bind (Spindle.Route.matched request) (fun (r : Spindle.Route.info) ->
        Spindle.Meta.find noindex r.meta)
  with
  | Some true ->
      Spindle.Response.add_headers [ ("x-robots-tag", "noindex") ] response
  | Some false | None -> response

let routes =
  [
    Spindle.get
      ~meta:Spindle.Meta.(empty |> add noindex true)
      Spindle.Path.(s "drafts")
      Spindle.Returns.text
      (let+ () = Spindle.Dep.return () in
       Ok "Not for search engines.");
  ]

let () =
  Eio_main.run @@ fun env ->
  Spindle.serve env ~middleware:[ security; hide_from_search ] routes
```

- **Order:** `[a; b]` is `a (b app)`: the first listed sees the request
  first and the response last.
- **It may answer alone**, without calling the handler -- a maintenance page,
  say. Around the handler, it may add headers
  (`Response.add_headers`) or cookies (`Response.add_cookies`) to the
  response, or answer a response of its own instead. It cannot rewrite a
  stream's body, which is written after the middleware has returned.
- **It cannot reroute.** The request is matched before any middleware runs;
  `Route.matched request` is that route's `Route.info`, or `None` when no
  route answered. A route puts a value there with `~meta`, as `/drafts` does
  above, and the middleware reads it with `Meta.find`. To send someone
  elsewhere, answer a redirect.
- **Declare its refusal codes** in `~refuses`, on
  `Spindle.serve` or `App.make`. A code nobody declared is logged as a bug,
  and raises in a test. These codes are not written into the OpenAPI document.
- **A raise is a `500`**, as a handler's is.
- Two are built in. `Middleware.headers` never overrides a header the route
  set itself, and `Cache.forever` keeps the assets a build names by their
  contents for a year ([static files](../tutorial/static-files.md)).

What one route needs -- a session, a [rate limit](rate-limits.md) -- is not
middleware but a dependency of that route, so it shows in the route and its
document. Logging is the server's own.
