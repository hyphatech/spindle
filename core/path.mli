(** Paths: which URLs a route answers, and the names and types of their
    parameters.

    {[
    let user_id = Path.int "user_id"
    let posts = Path.(s "users" / user_id / s "posts")
    let me = Path.(s "users" / s "me")
    ]}

    A path describes a URL and hands the handler nothing: a parameter reaches it
    as a dependency, [Spindle.param user_id], like any other input, so a
    dependency can be built from one -- load the user, check they may be read. A
    literal beats a parameter, so [me] answers [/users/me] wherever it is
    listed.

    {b A parameter is a path, and a path is not a parameter.}
    [Path.int "user_id"] is an [int param], which {!Spindle.param} reads;
    anything joined with {!(/)} is a {!path}, which it does not. Neither type
    leaves OCaml anything to fix at its first use, so a parameter made once is
    used in every path that has it. *)

type ('a, 'kind) t = ('a, 'kind) Path_repr.t
type 'a param = ('a, [ `Param ]) t
type path = (unit, [ `Path ]) t

(** {1 Parameters} *)

(** What a segment its codec cannot read makes of the request. *)
type unparsed = Path_repr.unparsed =
  | Invalid
      (** the default: a problem with the request, [400] at [path.<name>]
          ({!Refusal.invalid}), since the literals already chose the route and
          so the client sent a bad input *)
  | Next_route
      (** a URL this route does not answer, so another route whose path matches
          is asked, and [404] if none does -- for routes that differ only by a
          parameter's type:

          {[
          let by_id = Path.(s "posts" / int ~unparsed:Next_route "key")
          let by_slug = Path.(s "posts" / string "key")
          ]}

          Such routes give the parameter one name, since the API's document
          describes them as one operation ({!Openapi.document}). *)

val param : ?unparsed:unparsed -> string -> 'a Codec.t -> 'a param
(** [param name codec]: a segment read by [codec], percent-decoded first --
    [param "colour" colour] for a codec of the application's own -- and
    [unparsed] what one it cannot read makes of the request. An empty segment is
    never a parameter. *)

val string : ?unparsed:unparsed -> string -> string param
(** [param name Codec.string]: any segment -- [/users/Kim%20Li] is ["Kim Li"].
*)

val int : ?unparsed:unparsed -> string -> int param
(** [param name Codec.int]. *)

val int64 : ?unparsed:unparsed -> string -> int64 param
(** [param name Codec.int64]. *)

val rest : string -> string list param
(** Every remaining segment, zero or more, each percent-decoded:
    [Path.(s "static" / rest "file")] answers [/static/css/site.css] with
    [["css"; "site.css"]], and [/static] with [[]]. A segment holding an encoded
    ["/"] is still one segment, and an empty segment is never part of one. It
    ranks below every literal and parameter at its position, so a rest route at
    the root answers whatever no other route names, under any method -- a path
    one names is that route's, and [405] for the others. It is the last thing in
    its path -- one anywhere else is refused when the app is made -- and prints
    as [{file*}]. *)

(** {1 Paths} *)

val root : path
(** [/]: no segment. *)

val s : string -> path
(** A literal segment, compared with what the segment stands for once decoded.
    One that is empty or holds a ["/"] could never match, and is refused when
    the app is made. *)

val ( / ) : ('a, 'k) t -> ('b, 'l) t -> path
(** One, then the other. *)

val pattern : ('a, 'k) t -> string
(** [/users/{user_id}/posts]: what the access log writes, and what a route is
    named by. *)

(** {1 Printing} *)

type arg
(** A parameter and its value. *)

val arg : 'a param -> 'a -> arg

val url : ('a, 'k) t -> arg list -> (string, string) result
(** The path, printed: [url posts [ arg user_id 7 ]] is [Ok "/users/7/posts"],
    which matches [posts] again. Every segment is percent-encoded, so any text
    is one segment -- [.] and [..] as [%2E] and [%2E%2E], which a client would
    otherwise remove as it resolves the URL. A parameter of the path with no
    argument, an argument given twice, one for a parameter the path does not
    have, or one that prints as nothing -- an empty segment is never a parameter
    -- is [Error], naming it. The rest of a path prints each of its segments,
    and none at all for [[]] or [[""]]; an empty segment among others is [Error]
    too. *)
