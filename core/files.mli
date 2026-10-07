(** A directory served from disk as it is when a request arrives: uploads,
    generated reports, anything that changes while the server runs.

    {[
    Spindle.serve env
      (routes @ [ Spindle.Files.directory ~at:Path.(s "uploads") "var/uploads" ])
    ]}

    Where {!Static} reads a built site into memory once, this opens the file a
    request names when it arrives, and streams it.

    {b It never leaves its directory, twice over.} A segment that is empty, [.]
    or [..], that begins with a dot (unless [~dotfiles:true]), or that holds
    [/], [\ ] or NUL is [404] before anything is opened; and every file is
    opened beneath the directory as a subtree ([Eio.Path.with_subtree]), so a
    symlink that leads out of it is refused by the operating system as well.
    Nothing lists a directory: one is [404], or its [index] where one is named.

    {b An answer} is streamed in 64 KiB reads, with its length
    ({!Response.val-stream}'s [length]), a strong entity tag made of the file's
    size and its time to the nanosecond, and [Last-Modified]. [If-Match],
    [If-Unmodified-Since], [If-None-Match] and [If-Modified-Since] are answered
    as RFC 9110 §13.2.2 orders them -- [412] or [304] -- and one [Range] as
    §14.2 has it: [206] with [Content-Range], [416] for a range past the end,
    and several ranges, or an [If-Range] naming the file as it no longer is,
    answered whole. A file replaced between the answer's head and its body has
    its connection closed rather than send bytes of another file under this
    one's length. Write a file here by writing it elsewhere and renaming it over
    the old one: a file rewritten in place, at the same size within the clock's
    tick, would keep its tag. *)

val directory :
  ?at:Path.path ->
  ?index:string ->
  ?dotfiles:bool ->
  ?download:bool ->
  ?types:(string * string) list ->
  string ->
  Route.t
(** [directory path]: [GET <at>/{file*}], at the root unless told, over the rest
    of the path, as {!Static.route} is. [path] is the filesystem's, relative to
    the working directory unless it is absolute, and is checked when the server
    starts ({!App.start}): a path that is no directory is one {!Spindle.serve}
    will not start without.

    - [index] is the file a directory answers with: absent unless given.
    - [dotfiles] serves a name that begins with a dot: [false] unless told.
    - [download] answers every file with [Content-Disposition: attachment] and
      its name, [filename*] beside it for a name that is not plain ASCII (RFC
      6266): [false] unless told.
    - [types] adds to {!Static}'s table of content types, by extension, and wins
      over it. *)

val route :
  ?at:Path.path ->
  ?index:string ->
  ?dotfiles:bool ->
  ?download:bool ->
  ?types:(string * string) list ->
  Eio.Fs.dir_ty Eio.Path.t ->
  Route.t
(** The same, over a directory the program already holds --
    [Eio.Path.(Eio.Stdenv.cwd env / "uploads")], or a test's own -- so nothing
    is read when the server starts. *)
