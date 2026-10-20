(** An application's routes as an OpenAPI 3.2 document, and [/docs] to read it
    by ({!val-routes} serves both).

    Everything is read from {!Spindle.App.routes} and the routes' descriptions:
    requests from the decoding direction, answers from the encoding one, each
    description with a [kind] a component named by it. A route's codes are its
    responses, grouped by status, each with what it means. A credential
    ({!Spindle.Dep.val-credential}) is a security scheme. A route with the rest
    of a path ({!Spindle.Path.rest}) is left out: OpenAPI forbids a ["/"] in a
    path parameter's value, and such a route serves files. *)

val document :
  ?title:string -> ?version:string -> App.t -> (string, string list) result
(** The document, as JSON. Routes that share a method and a pattern -- told
    apart by a parameter's type ({!Path.Next_route}) -- are one operation: its
    parameter is any of their types, and it reads and answers what any of them
    does. [Error] names every description the generator could not name -- two
    different ones under one kind --; every two routes whose paths make one
    operation id, [/a-b] and [/a_b], which a generated client would give one
    name; every two whose paths differ only in a parameter's name, [/items/{id}]
    and [/items/{item}], which OpenAPI counts as one path; and every operation
    whose routes answer in different ways or read different bodies. *)

val report : App.t -> string list
(** Every place described loosely, each saying where: a route that may read more
    than it says (a [bind], a dependency with no [~needs]), and a value that may
    be any JSON ([Wiretype.Value.json]). Empty is a document that says
    everything. *)

val make :
  ?at:Path.path ->
  ?document:Path.path ->
  ?title:string ->
  ?version:string ->
  ?guard:unit Dep.t ->
  Route.t list ->
  (Route.t list, string list) result
(** The document of the routes it is given, at [document] ([/openapi.json]
    unless told), and Scalar's reference over it at [at] ([/docs]), with its
    scripts beneath it -- all from this server, so the page works offline and
    asks no other host for anything. The application adds them to the routes it
    described and makes its app once, so the document describes its API and not
    itself. Each is as public as the API it describes; an application that must
    not show it says who may with [guard], a dependency run first, whose refusal
    is the answer, as {!Metrics.routes}' is. [Error] names routes
    {!Spindle.App.make} refuses, what {!document} answers [Error] for, and a
    path with a parameter, which is no one place. {!val-routes} is this for
    routes written in source. *)

val routes :
  ?at:Path.path ->
  ?document:Path.path ->
  ?title:string ->
  ?version:string ->
  ?guard:unit Dep.t ->
  Route.t list ->
  Route.t list
(** [routes described]: {!make}, as routes to serve beside the ones they
    describe, as {!Health.routes} and {!Metrics.routes} are:

    {[
    Spindle.serve env (routes @ Spindle.Openapi.routes ~title:"Orders" routes)
    ]}

    What is described is what is passed, so a site served beside the API stays
    out of its document: [api @ site @ routes api].

    Raises [Invalid_argument] where {!make} answers [Error] -- routes
    {!Spindle.App.make} refuses, two descriptions under one kind, two routes of
    one operation id or of one path under two names, one operation answering two
    ways, a path with a parameter -- each written in source. A program that
    builds its routes at run time uses {!make}. *)
