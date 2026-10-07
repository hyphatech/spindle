(** Spindle: a web framework on Eio.

    An application is a list of {!Route}s. A route is one value -- a method, a
    {!Path}, what it {!Returns} and a handler -- and a handler asks for
    everything it needs as {!Dep}endencies, a path parameter as much as the
    body, composed with [let+] and [and+], and returns the value its model names
    or a {!Refusal}:

    {[
    open Spindle.Syntax

    let routes ~engine =
      [
        Spindle.post
          Spindle.Path.(s "v1" / s "analyze")
          (Spindle.Returns.json answer_json)
          (let+ query = Spindle.json query_json in
           analyze engine query);
      ]

    let () = Eio_main.run @@ fun env -> Spindle.serve env ~port:8112 routes
    ]} *)

module Status = Spindle_http.Status
module Meth = Spindle_http.Meth
module Codec = Codec

(** Cookies: the ones a response sets ({!Cookie.make}), and the ones a request
    carries, read as typed inputs like {!Query}'s, at [cookie.<name>]. *)
module Cookie : sig
  include module type of struct
    include Cookie
  end

  val optional : 'a named -> 'a option Dep.t
  (** The cookie's value, if the request carries it: one that does not parse is
      {!Refusal.invalid} at [cookie.<name>]. A {!signed} or {!encrypted} one
      that fails its signature, its seal or its age is [None]. *)

  val required : 'a named -> 'a Dep.t

  val encoded : string Codec.t
  (** Any text: written as one a cookie can hold, and read back as it was. *)
end

(** The binding operators a route's inputs are written with, and nothing else:
    [open Spindle.Syntax] at the top of a file.

    {[
    let+ id = Spindle.param user_id and+ now = Spindle.now in ...
    ]} *)
module Syntax : sig
  val ( let+ ) : 'a Dep.t -> ('a -> 'b) -> 'b Dep.t
  val ( and+ ) : 'a Dep.t -> 'b Dep.t -> ('a * 'b) Dep.t
end

module Request = Request
module Refusal = Refusal
module Key = Key
module Session = Session
module Cors = Cors
module Compress = Compress
module Rate = Rate
module Response = Response
module Event = Event
module Websocket = Spindle_http.Websocket
module Returns = Returns
module Meta = Meta
module Dep = Dep
module Query = Query
module Form = Form
module Header = Header
module Path = Path
module Route = Route
module Middleware = Middleware
module App = App
module Server = Server
module Test = Test
module Log = Log
module Trace = Spindle_http.Trace
module Metrics = Metrics
module Local = Spindle_http.Local
module Background = Background
module Alarm = Alarm
module Broadcast = Broadcast
module Body = Body
module Multipart = Multipart
module Static = Static
module Files = Files
module Openapi = Openapi
module Health = Health
module Zod = Zod

(** {1 Serving} *)

val serve :
  ?port:int ->
  ?host:string ->
  ?domains:int ->
  ?middleware:Middleware.t list ->
  ?codes:Refusal.Code.t list ->
  ?not_found:(Request.t -> Response.t) ->
  ?cors:Cors.t ->
  ?compress:Compress.t ->
  ?check_origin:bool ->
  ?trusted_origins:string list ->
  ?trailing_slash:App.trailing_slash ->
  ?now:(unit -> int) ->
  ?max_body:int ->
  ?max_header_bytes:int ->
  ?head_timeout_s:float ->
  ?idle_timeout_s:float ->
  ?body_timeout_s:float ->
  ?min_body_rate:int ->
  ?send_timeout_s:float ->
  ?discard_limit:int ->
  ?linger_s:float ->
  ?body_budget:int ->
  ?trusted_proxies:string list ->
  ?proxy_header:Server.proxy_header ->
  ?backlog:int ->
  ?max_connections:int ->
  ?stop:unit Eio.Promise.t ->
  ?drain_s:float ->
  ?on_stop:(unit -> unit) ->
  ?ready:(string -> unit) ->
  ?trace:Trace.exporter ->
  ?metrics:Metrics.t ->
  Eio_unix.Stdenv.base ->
  Route.t list ->
  unit
(** [serve env routes]: the routes made into an app ({!App.make}) and served
    ({!Server.run}) until the process is told to stop, everything taken from
    Eio's environment:

    {[
    let () = Eio_main.run @@ fun env -> Spindle.serve env routes
    ]}

    Each argument is {!App.make}'s or {!Server.run}'s, of the same name and
    default, and these are its own: [port] is [8080]; [now] is {!epoch_ms} of
    [env]'s clock; [stop] is {!Server.stop_on_signals}, so SIGTERM and SIGINT
    stop it cleanly, and a program that wants no handler passes a promise of its
    own; and [ready] prints the address it listens on to stdout. It opens a
    switch of its own for its own fibres, and leaves [Eio_main.run] to the
    program, which is where anything the routes need -- a pool, a client -- is
    made first. Logging is the program's to set up ({!Log.setup}).

    Raises [Invalid_argument] for routes {!App.make} refuses -- two that could
    answer one URL, a parameter named twice -- and for a limit or a proxy
    {!Server.run} refuses, before it listens: each is a constant written in
    source. What the routes read when the server starts -- a {!Static.directory}
    -- is read before it listens too ({!App.start}), from [env]'s filesystem,
    and one that cannot be read ends the program: an error in the log saying
    why, and exit code 1, since a server missing what it was written to serve is
    not the one that was written. A program that builds its routes at run time
    makes its app with {!App.make}, starts it with {!App.start}, and serves it
    with {!Server.run}. *)

val epoch_ms : _ Eio.Time.clock -> unit -> int
(** The clock's time in epoch milliseconds, which is what [now] is:
    [Spindle.epoch_ms (Eio.Stdenv.clock env)]. *)

(** {1 Blocking work} *)

val blocking : (unit -> 'a) -> 'a
(** [blocking f] runs [f] on a systhread and waits for it: for a library that
    blocks -- a C binding, a file read -- which on a fiber would stall every
    other fiber on the domain, since a fiber yields only at an effect. The
    request's log id goes with it ({!Log.carry}).
    {b Nothing inside [f] may perform an Eio effect or touch what a fiber owns}:
    there is no scheduler on that thread, so an effect raises there rather than
    waiting. *)

(** {1 Routes} *)

val route : Meth.t -> ('r, 'a, 'k) Route.maker
(** A route answering a method, [path returns inputs]. [`HEAD] is refused when
    the app is made: a [HEAD] is answered by the [GET] route, with its head
    alone. *)

val get : ('r, 'a, 'k) Route.maker
val post : ('r, 'a, 'k) Route.maker
val put : ('r, 'a, 'k) Route.maker
val patch : ('r, 'a, 'k) Route.maker
val delete : ('r, 'a, 'k) Route.maker

(** {1 Dependencies}

    What a handler can ask of any request. *)

val param : 'a Path.param -> 'a Dep.t
(** The value of one of the route's path parameters, typed by it. The route has
    matched, so it is there, and it is read in the first stage: a resource that
    does not exist refuses before the body is read. One that does not parse is
    {!Refusal.invalid} at [path.<name>] (see {!Path.val-param}).

    A route whose path has no such parameter is refused when the app is made,
    naming both -- except where the [param] is inside a {!Dep.bind}, which says
    nothing of what it reads: there it is {!Refusal.internal} when it runs. *)

val request : Request.t Dep.t

val now : int Dep.t
(** The application's clock, in epoch milliseconds. *)

val set_cookie : (Cookie.t -> unit) Dep.t
(** A function that sets a cookie on this request's answer: an endpoint that
    sets one takes it among its inputs and calls it, and one that sets nothing
    never mentions it. What it set goes with an [Ok] and never with a refusal.
    It is this request's alone; a call after the answer has gone -- from a fibre
    the endpoint left behind -- changes nothing and is logged as the route's
    bug. Whether the cookie is [Secure] is the framework's to say ({!Cookie}).

    {[
    let sign_out session set_cookie =
      Sessions.close session;
      set_cookie clear_session;
      Ok true

    Spindle.post Path.(s "sign-out") (Returns.json Wiretype.bool)
      (let+ session = session and+ set_cookie = Spindle.set_cookie in
       sign_out session set_cookie)
    ]} *)

val add_header : (string * string -> unit) Dep.t
(** {!set_cookie}, for a header: [add_header ("cache-control", "max-age=60")]. A
    field the framework writes itself -- [Content-Type], a framing field -- is
    the route's bug, as it is in any response ({!Response}). *)

val peer : string Dep.t

val client : string Dep.t
(** See {!Request.client}. *)

val request_id : string Dep.t

val body : string Dep.t
(** The body as it arrived: empty when there is none, {!Refusal.too_large} when
    there is too much. *)

val body_stream :
  ?content_type:(string -> bool) -> max:int -> unit -> Body.t Dep.t
(** The body, read as it arrives ({!Body}), up to [max] bytes: for a body too
    large to hold, which is why [max] is the route's own and not the server's
    [max_body], and has no default -- a route that takes uploads is where their
    size is decided.

    {[
    Spindle.post
      Path.(s "upload")
      (Returns.json receipt_json)
      (let+ body = Spindle.body_stream ~max:(64 * 1024 * 1024) () in
       save body)
    ]}

    It is the one input read last, as {!body} is: once every dependency that
    needs no body has refused nothing. The route's handler reads it with
    {!Body.read} and has it only while it runs. Its bytes count toward the
    server's [body_budget] a part at a time, from the read that gets a part to
    the next, and it must keep arriving at the server's [min_body_rate] over the
    whole body, measured only while the handler is inside a read. [content_type]
    is asked of the request's [Content-Type] in the first stage, as
    {!Dep.of_body}'s is.

    A route reads at most one body: one that lists this beside another
    [body_stream], {!body}, {!json} or an {!Dep.of_body} is refused when the app
    is made, because a body read as it arrives cannot also be read whole. *)

val multipart : ?max_head:int -> max:int -> unit -> Multipart.t Dep.t
(** The body as a [multipart/form-data]'s parts, read a part at a time as they
    arrive ({!Multipart}), up to [max] bytes: the upload {!body_stream} is for,
    already cut at its boundaries. It is {!body_stream} in all else -- the
    route's own [max], the server's body rate over the whole body, the budget
    held a part at a time, the one body its route reads -- and [max_head] bounds
    each part's head, 16 KiB, as the server bounds a request's.

    {[
    Spindle.post
      Path.(s "videos")
      (Returns.json receipt_json)
      (let+ parts = Spindle.multipart ~max:(4 * 1024 * 1024 * 1024) () in
       save_each parts)
    ]}

    A request whose [Content-Type] is not [multipart/form-data] is
    {!Refusal.unsupported_media_type}, and one that names no boundary
    {!Refusal.invalid} at [header.content-type], both before the body is read.
*)

val json :
  ?refusal:Refusal.Code.t * string ->
  ?examples:'a list ->
  'a Wiretype.t ->
  'a Dep.t
(** The body, decoded by its description. A request with no body reads as [{}],
    so a description whose members all have defaults accepts one. One that does
    not fit is {!Refusal.invalid} with every problem it has, each at its place
    -- [body.items[2].count], or [body] when it is not JSON at all -- with its
    code and a sentence. [refusal] is the route's own answer instead, a code and
    a sentence, with the problems as its detail, for the log; the dependency
    declares the code. [examples] are bodies it reads, for whoever documents the
    route.

    A request whose [Content-Type] names anything but [application/json] or an
    [application/...+json] is {!Refusal.unsupported_media_type}, before its body
    is read: a browser sends [text/plain] or a form from another site without
    asking first, and JSON only after a preflight, so accepting only JSON is
    what makes a forged request need permission it will not get. *)
