# Middleware

A middleware is a function from a handler to a handler. It wraps every route
and the not-found answer, for what applies to everything: headers, a
maintenance page, timing.

## Example: counting requests

```ocaml
(* A middleware of the application's own: every request is counted before
   any route answers it, and the answer says how many there have been.

   The count is an [Atomic] and not a [ref]: a request runs on any of the
   domains the server serves on, beside the others, so a [ref] would lose
   increments under load. *)

open Spindle.Syntax

let count = Atomic.make 0

let count_requests handler request =
  Atomic.incr count;
  handler request

let saw () = Ok (Printf.sprintf "Saw %i request(s)!" (Atomic.get count))

let routes =
  [
    (* [let+] over [Dep.return ()] runs [saw] on every request; [Dep.return
       (saw ())] would make the answer once, when the route is. *)
    Spindle.get Spindle.Path.root Spindle.Returns.text
      (let+ () = Spindle.Dep.return () in
       saw ());
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env ~middleware:[ count_requests ] routes
```

```console
$ curl localhost:8080/
Saw 1 request(s)!

$ curl localhost:8080/
Saw 2 request(s)!
```

## Writing middleware

Two middlewares: one built in, and one that counts requests by the route
they matched. A header one route needs is that route's own, written where
the route is:

```ocaml
open Spindle.Syntax

let security =
  Spindle.Middleware.headers
    [ ("x-content-type-options", "nosniff"); ("referrer-policy", "same-origin") ]

(* Counted by the route the request matched, never by its path, so
   /orders/1 and /orders/2 are one count. *)
let counts : (string, int) Hashtbl.t = Hashtbl.create 16
let lock = Eio.Mutex.create ()

let count_by_route handler request =
  let response = handler request in
  let route =
    match Spindle.Route.matched request with
    | Some r -> r.pattern
    | None -> "no route"
  in
  Eio.Mutex.use_rw ~protect:true lock (fun () ->
      Hashtbl.replace counts route
        (1 + Option.value (Hashtbl.find_opt counts route) ~default:0));
  response

let routes =
  [
    Spindle.get
      Spindle.Path.(s "drafts")
      Spindle.Returns.text
      (let+ add_header = Spindle.add_header in
       add_header ("x-robots-tag", "noindex");
       Ok "Not for search engines.");
  ]

let () =
  Eio_main.run @@ fun env ->
  Spindle.serve env ~middleware:[ security; count_by_route ] routes
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
  route answered. To send someone elsewhere, answer a redirect.
- **What one route needs is not middleware.** It is a dependency of that
  route, as `/drafts` adds its header above, so the route lists it.
- **Declare its refusal codes** in `~refuses`, on
  `Spindle.serve` or `App.make`. A code nobody declared is logged as a bug,
  and raises in a test. These codes are not written into the OpenAPI document.
- **A raise is a `500`**, as a handler's is.
- Two are built in. `Middleware.headers` never overrides a header the route
  set itself, and `Cache.forever` keeps the assets a build names by their
  contents for a year ([static files](../tutorial/static-files.md)).

What one route needs -- a session, a [rate
limit](rate-limits.md) -- is not middleware but a dependency of
that route, so it shows in the route and its document. Logging is the
server's own.
