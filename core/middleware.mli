(** What applies to every route: a function from a handler to a handler.

    {[
    let count_requests handler request =
      Atomic.incr count;
      handler request
    ]}

    {[
    Spindle.serve env ~middleware:[ count_requests ] routes
    ]}

    A middleware wraps the whole application -- every route and the not-found
    answer -- so a page gets what an endpoint gets. It cannot reroute a request,
    which is matched before it runs: a moved page is a redirect, which a
    middleware may answer, and a second address for a route is the route listed
    under both. It sees the request before the routes do and the response after,
    may answer without calling the handler at all, and may change the response's
    status and headers. It cannot rewrite a stream's body, which is written
    after it has returned.

    What one route needs is not middleware: it is a {!Dep}endency, or a function
    the route calls, so that a route's needs stay listed in the route. Logging
    is the server's own, and a limit on some routes is a dependency of theirs,
    so what is left here is what applies to everything. *)

type handler = Request.t -> Response.t

type t = handler -> handler
(** [middleware handler]. A request is matched from its method and path before
    any middleware runs, so one that is a policy for some routes asks the
    request which route it matched ({!Route.matched}) rather than reading the
    path.

    Listed where the application is made, in {!App.make}: [[a; b]] is
    [a (b app)], so the first listed is outermost -- it sees the request first
    and the response last, in the order the list is read. *)

val headers : (string * string) list -> t
(** Adds these headers to every response that does not already carry one by that
    name. *)
