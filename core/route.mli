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

type ('r, 'a, 'k) maker =
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?meta:Meta.t ->
  ('a, 'k) Path.t ->
  'r Returns.t ->
  'r Dep.t ->
  t
(** What makes a route -- {!Spindle.get} and its siblings:
    [path returns inputs]. [refuses] is the codes the route may refuse with
    beyond those its inputs carry ({!Dep.codes}) and the framework's own. A
    refusal with a code none of them declares is the route's bug: {!Test.call}
    raises on it, and the server logs it. [summary], [doc] and [tags] are what
    it says of itself ({!Meta.summary}, {!Meta.doc}, {!Meta.tags}), and [meta]
    anything else a package has a key for. *)

(** {1 What a route is}

    Everything below is known when the route is made, without a request. *)

type param = Route_repr.param = {
  name : string;
  shape : Codec.shape;
  kind : string option;  (** the codec's name, if it has one *)
  or_not_found : bool;
  rest : bool;  (** whether it takes the rest of the path ({!Path.rest}) *)
}
(** A parameter of the route's path. *)

type info = Route_repr.info = {
  meth : Spindle_http.Meth.t;
  pattern : string;  (** [/orders/{order_id}] *)
  params : param list;  (** in the order the path has them *)
  needs : Dep.need list;  (** what its inputs read *)
  credentials : Dep.credential list;
  returns : Returns.shape;
  codes : Refusal.Code.t list;
      (** its own and its inputs'; the framework's ({!Refusal.Code.framework})
          are not listed *)
  opaque : bool;
      (** whether its inputs may read more than [needs] says -- a {!Dep.bind},
          an {!Dep.of_request} with no [~needs] *)
  meta : Meta.t;
}

val info : t -> info

val matched : Request.t -> info option
(** The route this request matched -- what it reads, returns and refuses, and
    every {!Meta} key it carries -- or [None] when no route answers it: a [404],
    a [405], a trailing-slash redirect, or the not-found answer. The route table
    chooses before any middleware runs, so a middleware that is a policy for
    some routes reads it here:

    {[
    let limited handler request =
      match
        Option.bind (Route.matched request) (fun r -> Meta.find limit r.meta)
      with
      | Some n when over n request -> Response.refusal too_fast
      | Some _ | None -> handler request
    ]} *)

val pp_info : Format.formatter -> info -> unit
(** A route as a reader wants it, a few lines: its method and pattern and
    summary, then what it reads, what it answers and every code it may refuse
    with. *)
