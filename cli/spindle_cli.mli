(** An application's command line: its API, described from the routes.

    OCaml cannot load an application into a generic command, so each application
    calls {!run} from an executable of its own:

    {[
    let () = Spindle_cli.run ~name:"myapp" ~app:(Spindle.App.make routes) ()
    ]}

    [app] is only described -- no request reaches it, and it is never started --
    so a route that reads a resource ({!Spindle.Dep.of_resource}) is described
    without one: the routes are a plain value, and nothing they read at run time
    need exist.

    {v
    myapp api openapi [-o FILE]                  the OpenAPI 3.2 document
    myapp api zod [-o FILE]                      the TypeScript module of Zod schemas
    myapp api melange [-o FILE]                  the OCaml client for Melange
    myapp api check --openapi FILE --zod FILE [--melange FILE]
                                                 fail when any is not what the routes make
    v}

    Every command has [--help]. Nothing here is a database's: migrating one is a
    step of its own, before the server starts. *)

val run :
  name:string ->
  ?title:string ->
  app:(Spindle.App.t, string) result ->
  unit ->
  unit
(** [run ~name ~app ()] parses [Sys.argv], runs the command and exits: [0] when
    it did what was asked, [1] when it could not -- a stale file under [check],
    or an [app] that is an [Error] -- with the reason on stderr, [124] for a
    command line it cannot read, with its usage, and [125] for an exception
    nothing caught, as cmdliner answers them. Every command's [--help] lists
    these four, and no other. [name] is the command's own; [title] is what the
    API's document is called ([name]).

    [api openapi], [api zod] and [api melange] write what {!Spindle.Openapi},
    {!Spindle.Zod} and {!Spindle.Melange} make of the routes, and
    [api check --openapi FILE --zod FILE] fails when either committed file is
    not that -- and the Melange client too, given [--melange FILE] -- naming
    each that is not, reporting every place described loosely, and failing on
    those too with [--strict]. *)
