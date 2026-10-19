(** How long a browser may keep what the routes answer, apart from what they
    serve: a policy of the application's, given among its middleware.

    {[
    Spindle.serve env
      ~middleware:[ Spindle.Cache.forever ~under:[ "/assets/" ] ]
      (routes @ [ Spindle.Static.directory "dist" ])
    ]}

    Without one, nothing is kept unasked: {!Static} and {!Files} answer every
    file [no-cache] with a strong entity tag, so a browser keeps its copy and
    asks again each time, and is answered [304] while the file is the same. That
    is right for any file, and it is what a folder needs. *)

val forever : under:string list -> Middleware.t
(** Every successful [GET] or [HEAD] -- a [2xx] or a [304] -- whose path is
    under one of [under] is kept a year and never asked for again
    ([public, max-age=31536000, immutable]), whatever the route answered it
    with. It is for files whose names change when their bytes do: what a build
    names by a hash of its contents, as Vite's [/assets/] and Astro's
    [/_astro/], so a new version is a new name and nothing is kept stale. A
    failure is never kept.

    A prefix ends in ["/"], so [/assetsheet] is never under [/assets/]. Raises
    [Invalid_argument] for one that does not begin and end with ["/"]: a prefix
    is a constant written in source. *)
