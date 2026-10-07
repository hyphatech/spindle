# Middleware

A middleware is a function from a handler to a handler, listed where the app
is made. It wraps every route and the not-found answer, so a page gets what
an endpoint gets:

```ocaml
let security =
  Spindle.Middleware.headers
    [ ("x-content-type-options", "nosniff"); ("referrer-policy", "same-origin") ]

let closed_for_maintenance _handler _req =
  Spindle.Response.refusal (Spindle.Refusal.make closed "Back in a minute.")

(* A policy for some routes reads the route, never the path. *)
let limit : int Spindle.Meta.key = Spindle.Meta.key ()

let limited handler req =
  match Option.bind (Spindle.Route.matched req) (fun i -> Spindle.Meta.find limit i.meta) with
  | Some n when over n req -> Spindle.Response.refusal (Spindle.Refusal.make slow_down "Too fast.")
  | Some _ | None -> handler req

Spindle.App.make ~middleware:[ security; limited ] ~codes:[ closed; slow_down ]
  ~not_found:page routes
```

- **The route is the request's to say:** the request is matched from its
  method and path before any middleware runs, and `Route.matched request`
  is the matched route's `Route.info` -- what it reads, returns and
  refuses, and every `Meta` key it carries -- or `None` when no route
  answers: a `404`, a `405`, a trailing-slash redirect, or the not-found
  answer. A
  middleware that does not care never asks. It follows that middleware
  cannot reroute: the route matched is the route that answers, and a
  middleware that wants another URL answers with a redirect.
- **Less of it than elsewhere:** logging is the server's own, one line per
  request whatever became of it; what a route needs -- a session, a limit
  -- is a dependency it lists; so a middleware is for what applies to
  everything: headers, a maintenance page, timing.

- **In the order listed:** `[a; b]` is `a (b app)`, so the first listed sees
  the request first and the response last. Nothing is registered anywhere
  else.
- **It may answer alone** -- the handler never runs -- and it may change a
  response's status and headers (`Response.add_headers`). It cannot rewrite a
  stream's body, which is written after it has returned.
- **A raise is a `500`**, as a handler's is, and the access log records
  whatever the middleware finally answered.
- **Its codes are declared where it is listed:** `~codes` names what the
  middleware and the not-found answer may refuse with, held to what a
  route's codes are -- one meaning to a name, a challenge on a `401` -- and
  judged on the answer the whole chain gave, so a code nobody declared is
  logged, and raised in a test, whether a route ran or not. They are not in
  the API's document, since a policy for some routes would have its codes
  claimed by every operation.
- **What one route needs is not middleware** but a dependency, so a route's
  needs stay listed in the route. `Middleware.headers` is the one built-in;
  it never overrides a header the route set itself.

## A count of every request

```ocaml
--8<-- "middleware.ml"
```
