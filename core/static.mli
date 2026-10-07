(** A directory of files -- a built site, its assets -- served by the process.

    {[
    Spindle.serve env
      (routes
      @ [
          Spindle.Static.directory ~not_found:"/404.html"
            ~immutable:[ "/_astro/" ] "dist";
        ])
    ]}

    {b The whole directory is read into memory when it is loaded}, and nothing
    maps a request onto the filesystem afterwards: a request is a lookup among
    the files that were there, so a traversal has nothing to traverse and [/../]
    is a miss rather than a file. Symlinks are followed then, by the operator's
    own build, and never for a request. The cost is that a changed file needs a
    restart, which is what a deployment is; a directory that does not fit in
    memory is served by something that is not this.

    Three rules decide what a path answers, and they are the whole of it:
    - a directory is its index, so [/about] is [/about/index.html] and [/] is
      [/index.html];
    - a path under a shell prefix -- [/orders/] -- is the shell document, with a
      [200], for pages whose ids are made at run time and have no file;
    - anything else with no file is the not-found document, with a [404], or the
      framework's [404] when there is none.

    A path is one spelling: [/about/] is the application's trailing-slash policy
    ({!App.type-trailing_slash}), which with [Redirect] sends it to [/about]. *)

type t

val load :
  ?index:string ->
  ?not_found:string ->
  ?shell:string * string list ->
  ?immutable:string list ->
  ?types:(string * string) list ->
  _ Eio.Path.t ->
  (t, string) result
(** [load dir] reads every file under [dir]. Each optional but [index] is absent
    unless given, so a directory loaded with none serves its files and its
    indexes and nothing else.

    - [index] is the file a directory answers with, ["index.html"] unless told.
    - [not_found] is the file served, with a [404], for a path with no file:
      ["/404.html"].
    - [shell] is a file and the prefixes it answers with a [200]:
      [("/app/index.html", [ "/orders/"; "/invites/" ])]. A prefix ends in
      ["/"], so [/ordersheet] is never under [/orders/].
    - [immutable] is the prefixes whose files are fingerprinted by the build,
      cached for a year: [[ "/_astro/" ]]. Every other file is [no-cache], and
      nothing is in between, since a middle value for a document is how a stale
      page outlives the assets it names.
    - [types] adds to the table of content types, by extension:
      [[ (".wasm", "application/wasm") ]], and wins over it. An extension in
      neither is served as bytes, because a wrong type is worse than a download.

    Paths are the ones a request asks for, with their leading slash, below where
    the route is mounted. [Error], in a sentence, when [dir] is not a directory,
    when a file cannot be read, or when [not_found] or [shell] names a file it
    does not hold. *)

val route : ?at:Path.path -> t -> Route.t
(** [GET <at>/{file*}], at the root unless told: [route ~at:Path.(s "static")].
    [HEAD] is answered with it.

    It is a route over {!Path.rest}, so it takes only the paths no other route
    names, under any method: every endpoint is asked first, and another method
    at a path under it is [405], at the root as anywhere -- [POST /nothing] is
    [405 Allow: GET, HEAD].

    Every file carries a strong entity tag, its digest, and is answered as
    {!Files} answers one: its preconditions -- [If-Match], [If-None-Match] -- as
    RFC 9110 §13.2.2 orders them, [412] or a [304] with no body, and one [Range]
    as §14.2 has it, [206] with [Content-Range] or [416] past the end, several
    ranges or an [If-Range] naming another version answered whole. The not-found
    document is an error page, and none of that applies to it. *)

val directory :
  ?at:Path.path ->
  ?index:string ->
  ?not_found:string ->
  ?shell:string * string list ->
  ?immutable:string list ->
  ?types:(string * string) list ->
  string ->
  Route.t
(** [directory path] is {!route} of {!load} [path], read when the server starts
    rather than before the routes are made, so the table stays a constant:
    [Spindle.serve env [ Static.directory "public" ]]. [path] is the
    filesystem's, relative to the working directory unless it is absolute, and
    every optional is {!load}'s. A directory that cannot be read is one
    {!Spindle.serve} will not start without ({!App.start}); a test, which has no
    filesystem to start from, loads it with {!load} and serves it with {!route}.
*)

val files : t -> int
(** How many files were loaded. *)
