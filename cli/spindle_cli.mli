(** An application's command line: its API, described from the routes.

    OCaml cannot load an application into a generic command, so each application
    calls {!run} from an executable of its own:

    {[
    let () = Spindle_cli.run ~name:"myapp" ~app ()
    ]}

    {v
    myapp api openapi [-o FILE]                  the OpenAPI 3.2 document
    myapp api zod [-o FILE]                      the TypeScript module of zod schemas
    myapp api check --openapi FILE --zod FILE    fail when either is not what the routes make
    v}

    Every command has [--help]. Nothing here is a database's: migrating one is a
    step of its own, before the server starts. *)

type app =
  Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> (Spindle.App.t, string) result
(** How an application makes its app for the commands: inside an Eio loop the
    command line runs. The app is only described -- no request reaches it -- so
    it is made from nothing a request would need: a database it cannot reach, a
    service it does not call. *)

val run : name:string -> ?title:string -> app:app -> unit -> unit
(** Parses [Sys.argv], runs the command and exits: [0] when it did what was
    asked, [1] when it could not -- a stale file under [check] -- with the
    reason on stderr, and [124] for a command line it cannot read, with its
    usage, as cmdliner answers one. [name] is the command's own; [title] is what
    the API's document is called ([name]).

    [api openapi] and [api zod] write what {!Spindle.Openapi} makes of the
    routes, and [api check --openapi FILE --zod FILE] fails when either
    committed file is not that, reporting every place described loosely -- and
    failing on those too with [--strict]. *)
