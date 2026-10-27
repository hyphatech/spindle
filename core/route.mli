(** A route: a method, a path, what it returns and one list of inputs -- one
    value, so an endpoint is declared in one place, in the order a request line
    has it.

    {[
    let order_id = Path.int "order_id"

    let order =
      Spindle.get ~refuses:[ gone ]
        Path.(s "orders" / order_id)
        (Returns.json order_json)
        (let+ id = Spindle.param order_id and+ now = Spindle.now in
         find_order id ~now)
    ]}

    The handler takes no arguments of its own -- a path parameter is an input
    like a query parameter or the body -- and returns what {!Returns} says, so
    what a route reads, what it returns and every code it may refuse with are
    known without running it. *)

type t = Route_repr.t

(** What a route lets a request make it hold or wait for, in place of the
    server's ({!Server.Limits}), under the same names: only those a route can
    apply, since the rest act before a route is chosen, between requests or on
    the whole server. A limit it does not give is the server's.

    {[
    let import =
      Spindle.post
        ~limits:(Spindle.Route.Limits.make ~max_body:(64 * 1024 * 1024) ())
        Path.(s "import")
        (Returns.json receipt_json)
        (let+ body = Spindle.body_stream () in
         save body)
    ]} *)
module Limits : sig
  type t = Limits_repr.route

  val make :
    ?max_body:int ->
    ?body_timeout:Mtime.Span.t ->
    ?min_body_rate:int ->
    unit ->
    t
  (** Each as {!Server.run} describes it, for this route's body: [max_body] the
      longest, [body_timeout] how long it has from its first read, and
      [min_body_rate] the bytes a second it must keep up after. A body read
      whole is held, so a route that reads it whole with a [max_body] above the
      server's [body_budget] is a bug, reported where it is read: [500], an
      [error] line naming the route, and {!Test.call} raises. One that streams
      it holds a part at a time, and is bounded by [max_body] alone.

      Raises [Invalid_argument] for one out of its range, as
      {!Server.Limits.make} does: a negative [max_body], a [min_body_rate] below
      one, or a [body_timeout] of zero. *)
end

type ('r, 'a, 'k) maker =
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?access_log:Logs.level ->
  ?compress:Compress.t ->
  ?cors:Cors.t ->
  ?limits:Limits.t ->
  ('a, 'k) Path.t ->
  'r Returns.t ->
  'r Dep.t ->
  t
(** What makes a route -- {!Spindle.get} and its siblings:
    [path returns inputs]. [refuses] is the codes the route may refuse with
    beyond those its inputs carry ({!Dep.codes}) and the framework's own its
    document lists from what it reads ({!Refusal.Code}). A refusal with a code
    none of them declares is the route's bug: {!Test.call} raises on it, and the
    server logs it. [summary], [doc] and [tags] are what it says of itself, for
    its document. [access_log] is the level of its line in the access log,
    [Info] unless given: a route something asks every few seconds -- a probe --
    gives [Debug], so its lines are there when asked for and bury nothing.
    [compress] is its compression policy in place of the app's ({!App.make}'s
    [compress]): {!Compress.none} for a route whose answers are never
    compressed, as one that answers a secret beside what a request sent. [cors]
    is its CORS policy in place of the app's ({!App.make}'s [cors]): an API's
    routes that other sites call, under an app whose pages allow none, or
    {!Cors.none} for one route that allows none under an app that allows some.
    Routes that share settings share a maker:
    [let api_get = Spindle.get ~cors:app_site]. [limits] are its own in place of
    the server's ({!Limits}). *)

(** {1 What a route is}

    Everything below is known when the route is made, without a request. *)

type param = Route_repr.param = {
  name : string;
  schema : Wiretype.Schema.t;  (** what its description says of it *)
  kind : string option;
      (** the name of its description's kind or enum, if it has one *)
  unparsed : Path.unparsed;
      (** what a segment it cannot read makes of a request *)
  rest : bool;  (** whether it takes the rest of the path ({!Path.rest}) *)
}
(** A parameter of the route's path. *)

(** Who may call a route, as what it reads declares: {!Access}'s. A route that
    reads neither is anyone's. *)
type access = Dep_repr.access =
  | Caller  (** whoever is calling: a caller read ({!Access.caller}, a check) *)
  | Checked of { policy : string; action : string option }
      (** a policy's check of an action, by their names: [None] for
          {!Access.check}, whose actions are known only as it runs *)

type info = Route_repr.info = {
  meth : Spindle_http.Meth.t;
  pattern : string;  (** [/orders/{order_id}] *)
  params : param list;  (** in the order the path has them *)
  needs : Dep.need list;
      (** what its inputs read, each input once: two dependencies reading one by
          where and name -- a header's name without case -- are one need,
          required where either is *)
  credentials : Dep.credential list;
  access : access list;
      (** who may call it, each once: a caller and every check it reads; none
          for a route anyone may call *)
  returns : Returns.shape;
  codes : Refusal.Code.t list;
      (** its own and its inputs'; the framework's its document lists from what
          it reads ({!Refusal.Code}) are not listed *)
  opaque : bool;
      (** whether its inputs may read more than [needs] says -- a {!Dep.bind},
          an {!Dep.of_request} with no [~needs] *)
  summary : string option;
  doc : string option;
  tags : string list;
  access_log : Logs.level;  (** the level of its line in the access log *)
  compress : Compress.t option;
      (** its own compression policy; [None] where it has the app's *)
  cors : Cors.t option;
      (** its own CORS policy; [None] where it has the app's *)
  limits : Limits.t;  (** its own limits *)
}

val info : t -> info

val matched : Request.t -> info option
(** The route this request matched -- what it reads, returns and refuses -- or
    [None] when no route answers it: a [404], a [405], the framework's
    [OPTIONS], a trailing-slash redirect, or the not-found answer. The route
    table chooses before any middleware runs, so a middleware that counts or
    times requests reads the route here, by its pattern rather than its path:

    {[
    let per_route handler request =
      let response = handler request in
      let pattern =
        match Route.matched request with Some r -> r.pattern | None -> "none"
      in
      count pattern;
      response
    ]}

    What one route needs is not a middleware's: it is a dependency of the
    route's, so the route lists it ({!Middleware}). *)

val pp_info : Format.formatter -> info -> unit
(** A route as a reader wants it, a few lines: its method and pattern and
    summary, then what it reads, what it answers and every code it may refuse
    with. *)
