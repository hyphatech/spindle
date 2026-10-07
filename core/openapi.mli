(** An application's routes as an OpenAPI 3.2 document, and [/docs] to read it
    by ({!docs} serves both).

    Everything is read from {!Spindle.App.routes} and the routes' descriptions:
    requests from the decoding direction, answers from the encoding one, each
    description with a [kind] a component named by it. A route's codes are its
    responses, grouped by status, each with what it means. A credential
    ({!Spindle.Dep.val-credential}) is a security scheme. A route with the rest
    of a path ({!Spindle.Path.rest}) is left out: OpenAPI forbids a ["/"] in a
    path parameter's value, and such a route serves files. *)

val document :
  ?title:string -> ?version:string -> App.t -> (string, string list) result
(** The document, as JSON. [Error] names every description the generator could
    not name: two different ones under one kind. *)

val report : App.t -> string list
(** Every place described loosely, each saying where: a route that may read more
    than it says (a [bind], a dependency with no [~needs]), and a value that may
    be any JSON ([Wiretype.Value.json]). Empty is a document that says
    everything. *)

val routes :
  ?at:Path.path ->
  ?document:Path.path ->
  ?title:string ->
  ?version:string ->
  Route.t list ->
  (Route.t list, string list) result
(** The document of the routes it is given, at [document] ([/openapi.json]
    unless told), and Scalar's reference over it at [at] ([/docs]), with its
    scripts beneath it -- all from this server, so the page works offline and
    asks no other host for anything. The application adds them to the routes it
    described and makes its app once, so the document describes its API and not
    itself. [Error] names routes {!Spindle.App.make} refuses, descriptions the
    document could not name, and a path with a parameter, which is no one place.
    {!docs} is this for routes written in source. *)

val docs :
  ?at:Path.path ->
  ?document:Path.path ->
  ?title:string ->
  ?version:string ->
  Route.t list ->
  Route.t list
(** [docs routes]: {!val-routes}, as routes to serve beside the ones they
    describe:

    {[
    Spindle.serve env (routes @ Spindle.Openapi.docs ~title:"Orders" routes)
    ]}

    What is described is what is passed, so a site served beside the API stays
    out of its document: [api @ site @ docs api].

    Raises [Invalid_argument] where {!val-routes} answers [Error] -- routes
    {!Spindle.App.make} refuses, two descriptions under one kind, a path with a
    parameter -- each written in source. A program that builds its routes at run
    time uses {!val-routes}. *)
