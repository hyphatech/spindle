(** An application: routes, what answers everything they do not match, and what
    applies to all of it.

    A request is matched by method and path. A path some route claims under
    another method is [405] with [Allow]; a path no route claims is the
    application's not-found answer, or [404]. A method no route declares and the
    framework does not know -- [PROPFIND], say, in an application that answers
    none -- is [501], before the not-found answer, since nothing here implements
    it. [HEAD] is answered by the [GET] route. A handler or a middleware that
    raises is [500], with the exception in the log -- except cancellation, which
    is how Eio stops work nobody is waiting for, and so is never caught here. *)

type t

(** Whether [/users/kim/] is [/users/kim]. *)
type trailing_slash =
  | Strict  (** a different path, which no route matches *)
  | Redirect  (** a [308] to the path without it *)

val make :
  ?middleware:Middleware.t list ->
  ?codes:Refusal.Code.t list ->
  ?not_found:(Request.t -> Response.t) ->
  ?cors:Cors.t ->
  ?compress:Compress.t ->
  ?check_origin:bool ->
  ?trusted_origins:string list ->
  ?trailing_slash:trailing_slash ->
  Route.t list ->
  (t, string) result
(** Refuses, naming the route: two routes of one method that could both answer
    one URL -- the second could never be reached; a code of one name declared
    with two statuses, docs or challenges; a [401] code with no challenge
    ({!Refusal.Code.make}); a literal segment that is empty or holds a ["/"]; a
    path naming one parameter twice; and a handler that reads a path parameter
    ({!Spindle.param}) its path does not have. A literal beats a parameter
    wherever the routes are listed, and a parameter that may decline
    ({!Path.val-param}'s [or_not_found]) beats one that may not; between two
    that both may, the one listed first answers. [not_found] answers every
    request no route claims, once the framework has answered its own -- a [405],
    a [501], a trailing-slash redirect -- with whatever status it gives; without
    it the answer is {!Refusal.not_found}. A rest route at the root
    ({!Path.rest}) takes every path no other route names, so behind one it is
    never reached. [middleware] wraps the routes and the not-found answer alike,
    the first listed outermost (see {!Middleware.t}). [codes] are what they may
    refuse with, held to what a route's are -- one meaning to a name, a
    challenge on a [401] -- and not written into the API's document, since a
    middleware that is a policy for some routes would have them claimed by every
    operation. [trailing_slash] is [Strict] unless the application asks, because
    two spellings of one resource split its links and its caches. A raise -- a
    handler's, a middleware's, [not_found]'s -- is {!Refusal.internal}'s [500]
    and an [error] line with its backtrace. [cors] lets other sites' pages call
    the routes it covers ({!Cors}): absent unless given, since the origin check
    and the browser's own refusal are what keep a site's answers its own.
    [compress] writes answers with gzip where a client takes it ({!Compress}):
    off unless given.

    {b Forgery.} Every request by a method that changes something -- anything
    but [GET], [HEAD] and [OPTIONS] -- that a browser sent from another site is
    {!Refusal.cross_origin}, before any route or the not-found answer sees it. A
    browser says where a request came from: [Sec-Fetch-Site] passes it when
    [same-origin] or [none], and otherwise only when its [Origin] is one of
    [trusted_origins] (each written as the browser writes it,
    [https://example.com]); a browser too old to send that is judged by
    [Origin], which passes when trusted or when it names the host the request
    was sent to ({!Request.host}). [Origin: null] never passes. A request with
    neither header is not from a browser -- curl, an app, another server -- and
    passes, since forgery is an attack a browser is made to carry out.
    [check_origin:false] turns this off, for an application that has other
    protection; [SameSite] cookies are a second layer, not a replacement. A form
    a browser posts is read under this check and nothing else, so an application
    that turns it off has turned off what protects its forms. *)

val routes : t -> Route.info list
(** Every route, in the order listed: what each reads, answers and may refuse
    with, and what it says of itself -- enough to document the application
    without running it. *)

(** What an answer held that nobody declared. *)
type undeclared =
  | Code of Refusal.Code.t
      (** a refusal's code that is neither the framework's, one of [make]'s
          [codes] nor one the matched route declares *)
  | Status of Spindle_http.Status.t
      (** a success status the matched route does not list, where it lists the
          ones it may answer *)

type answered = {
  route : string option;
      (** the pattern of the route that answered, [/orders/{order_id}]; [None]
          when no route did -- the not-found answer, a [404], a [405], a
          redirect, or a middleware that answered alone *)
  undeclared : undeclared option;
      (** what in the answer nobody declared: a bug, which {!Test.call} raises
          on and the server logs *)
  access : Logs.level;
      (** the level of its line in the access log: the matched route's
          {!Meta.access}, and [Info] when it has none or none matched *)
  gzip : int option;
      (** the level its body is to be written with gzip at, where the app's
          [compress] took it ({!Compress}) *)
}
(** What answering a request taught the framework, beside the response. *)

val handle : t -> Request.t -> body:Body.source -> Response.t * answered
(** Answers a request: the seam that a connection loop -- {!Server}'s, or
    another -- and {!Test.call} drive. [body] reads its body, whole or a part at
    a time, and is asked only by a route that needs it, once its other
    dependencies refused nothing, and only while its handler runs; middleware
    and the not-found answer never see it. *)

val start : t -> fs:_ Eio.Path.t -> (unit, string) result
(** Reads what the routes read when the server starts -- the directory of a
    {!Static.directory} -- from [fs], in the order they were listed, and says in
    a sentence, naming the route, why the first that could not did not.
    {!Spindle.serve} calls it before it serves; a program that runs
    {!Server.run} itself calls it first, since a route that was never started
    answers [500] and says so in the log. *)
