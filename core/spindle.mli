(** Spindle: a web framework on Eio.

    An application is a list of {!Route}s. A route is one value -- a method, a
    {!Path}, what it {!Returns} and a handler -- and a handler asks for
    everything it needs as {!Dep}endencies, a path parameter as much as the
    body, composed with [let+] and [and+], and returns the value its model names
    or a {!Refusal}. What the application holds -- here an engine -- is a
    {!Dep.of_resource}, handed to the server where it starts, so the routes are
    a value:

    {[
    open Spindle.Syntax

    let engine : Engine.t Spindle.Dep.t = Spindle.Dep.of_resource "engine"

    let routes =
      [
        Spindle.post
          Spindle.Path.(s "v1" / s "analyze")
          (Spindle.Returns.json answer_json)
          (let+ engine = engine and+ query = Spindle.json query_json in
           analyze engine query);
      ]

    let () =
      Eio_main.run @@ fun env ->
      Spindle.serve env ~port:8112
        ~resources:[ Spindle.Dep.resource engine (Engine.load ()) ]
        routes
    ]} *)

module Status = Spindle_http.Status
module Meth = Spindle_http.Meth

(** Cookies: the ones a response sets ({!Cookie.make}), and the ones a request
    carries, read as typed inputs like {!Query}'s, at [cookie.<name>]. *)
module Cookie : sig
  include module type of struct
    include Cookie
  end

  val optional : 'a named -> 'a option Dep.t
  (** The cookie's value, if the request carries one that reads. One that does
      not -- a value its description does not read, a broken escape, or a
      {!signed} or {!encrypted} one that fails its signature, its seal or its
      age -- is [None], and a [debug] line naming the cookie: the server wrote
      it and the browser only kept it, so one an older deploy wrote is no
      refusal. *)

  val required : 'a named -> 'a Dep.t
  (** {!optional}, refused as missing at [cookie.<name>] when it is [None]. *)
end

(** The binding operators a route is written with, and nothing else:
    [open Spindle.Syntax] at the top of a file. [let+] and [and+] read its
    inputs; [let*] goes on through the [result] its handler answers, so a
    handler opens one module for both, where [Result.Syntax]'s own [let+] would
    hide the inputs'.

    {[
    let+ id = Spindle.param user_id and+ now = Spindle.now in
    let* order = find_order id ~now in
    Ok order
    ]} *)
module Syntax : sig
  val ( let+ ) : 'a Dep.t -> ('a -> 'b) -> 'b Dep.t
  val ( and+ ) : 'a Dep.t -> 'b Dep.t -> ('a * 'b) Dep.t

  val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result
  (** [Result.bind]. *)
end

module Request = Request
module Refusal = Refusal
module Key = Key
module Session = Session
module Cors = Cors
module Compress = Compress
module Cache = Cache
module Rate = Rate
module Response = Response
module Event = Event
module Websocket = Spindle_http.Websocket
module Returns = Returns
module Dep = Dep
module Bearer = Bearer
module Access = Access
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
module Melange = Melange

(** {1 Serving} *)

val serve :
  ?port:int ->
  ?host:string ->
  ?domains:int ->
  ?resources:Dep.resource list ->
  ?middleware:Middleware.t list ->
  ?refuses:Refusal.Code.t list ->
  ?not_found:(Response.t, Refusal.t) result Dep.t ->
  ?cors:Cors.t ->
  ?compress:Compress.t ->
  ?check_origin:bool ->
  ?trusted_origins:string list ->
  ?trailing_slash:App.trailing_slash ->
  ?read_clock:(unit -> Ptime.t) ->
  ?limits:Server.Limits.t ->
  ?trusted_proxies:string list ->
  ?proxy_header:Server.proxy_header ->
  ?stop:unit Eio.Promise.t ->
  ?on_stop:(unit -> unit) ->
  ?ready:(string -> unit) ->
  ?trace:Trace.exporter ->
  ?metrics:Metrics.t ->
  ?keys:Key.ring ->
  < net : _ Eio.Net.t
  ; clock : _ Eio.Time.clock
  ; mono_clock : _ Eio.Time.Mono.t
  ; domain_mgr : _ Eio.Domain_manager.t
  ; fs : _ Eio.Path.t
  ; .. > ->
  Route.t list ->
  unit
(** [serve env routes]: the routes made into an app ({!App.make}) and served
    ({!Server.run}) until the process is told to stop, with the capabilities it
    uses taken from [env] -- the network it listens on, the clocks, the domains
    it serves on and the filesystem a route reads as it starts -- and nothing
    else, so Eio's whole environment is one value that has them:

    {[
    let () = Eio_main.run @@ fun env -> Spindle.serve env routes
    ]}

    Each argument is {!App.make}'s, {!App.start}'s or {!Server.run}'s, of the
    same name and default, and these are its own: [port] is [8080]; [read_clock]
    reads [env]'s clock ({!of_clock}), and its limits ({!Rate}) are timed on
    [env]'s monotonic clock; [stop] is {!Server.stop_on_signals}, so SIGTERM and
    SIGINT stop it cleanly, and a program that wants no handler passes a promise
    of its own; and [ready] prints the address it listens on to stdout. It opens
    a switch of its own for its own fibres, and leaves [Eio_main.run] to the
    program, which is where anything the routes need -- a pool, a client -- is
    made first, and handed over as [resources] ({!Dep.of_resource}), and where
    the secret its signed and encrypted cookies are sealed under is read, and
    handed over as [keys] ({!Key.of_secret}). Logging is the program's to set up
    ({!Log.setup}).

    Raises [Invalid_argument] for routes {!App.make} refuses -- two that could
    answer one URL, a parameter named twice -- and for a limit or a proxy
    {!Server.run} refuses, before it listens: each is a constant written in
    source. What the routes read when the server starts -- a {!Static.directory}
    or a {!Files.directory} -- is read before it listens too ({!App.start}),
    from [env]'s filesystem, and the [resources] they read are checked: a
    directory that cannot be read, or a resource a route reads that [resources]
    does not hold, ends the program, as does a [host] and [port] it cannot
    listen on ({!Server.listen_error}): one line saying why -- in the log, or on
    stderr where the program set none up -- and exit code 1, since a server
    missing what it was written to serve is not the one that was written. A
    program that builds its routes at run time makes its app with {!App.make},
    starts it with {!App.start} on [env]'s monotonic clock, which times its
    limits ({!Rate}), and serves the instance that answers with {!Server.run}.
*)

val of_clock : _ Eio.Time.clock -> Ptime.t
(** The clock's time now, {!Spindle_http.Instant.of_clock}: what [read_clock]
    reads, [fun () -> Spindle.of_clock (Eio.Stdenv.clock env)]. A clock reads a
    time within the years 0000 to 9999, and one that does not is read as the
    nearest instant in them. *)

val until : now:Ptime.t -> Ptime.t -> Mtime.Span.t
(** [until ~now deadline]: how long from [now] until [deadline], rounded up to
    the nanosecond, and zero once it has passed -- a wait cannot be negative. It
    is how a wait until an instant is worked out, and the one place a deadline
    already passed is decided:

    {[
    Spindle.Alarm.set alarms ~key ~after:(Spindle.until ~now ends)
      ~what:"a turn's clock" (fun () -> end_turn game)
    ]} *)

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

val now : Ptime.t Dep.t
(** The application's clock: the instant the request is answered at. *)

val keys : Key.ring Dep.t
(** The keys the server was given ([serve ~keys]), for a handler that signs or
    seals something of its own with {!Key.sign} or {!Key.seal} -- a link's
    token, an OAuth state. A route that reads it is refused where the server
    starts when none were given, as one that reads a signed cookie is. *)

val set_cookie : (Cookie.t -> unit) Dep.t
(** A function that sets a cookie on this request's answer: a handler that sets
    one takes it among its inputs and calls it, and one that sets nothing never
    mentions it. What it set goes with the answer, an [Ok] or a refusal. It is
    this request's alone; a call after the answer has gone -- from a fibre the
    handler left behind -- changes nothing and is logged as the route's bug.
    Whether the cookie is [Secure] is the framework's to say ({!Cookie}).

    {[
    let theme = Spindle.Cookie.named "theme" Wiretype.string

    let save_theme =
      Spindle.post
        Path.(s "theme" / name)
        Returns.text
        (let+ name = Spindle.param name and+ set_cookie = Spindle.set_cookie in
         set_cookie (Spindle.Cookie.make theme name);
         Ok "Saved.")
    ]} *)

val add_header : (string * string -> unit) Dep.t
(** {!set_cookie}, for a header: [add_header ("cache-control", "max-age=60")]. A
    field the framework writes itself -- [Content-Type], a framing field -- is
    the route's bug, as it is in any response ({!Response}). *)

val peer : string Dep.t

val client_ip : string Dep.t
(** See {!Request.client_ip}. *)

val request_id : string Dep.t

val client_gone : unit Eio.Promise.t Dep.t
(** See {!Request.client_gone}: what an events route's producer hands
    {!Broadcast.forward} as [~until], so a client that leaves a quiet topic ends
    its producer at once.

    {[
    let+ room = Spindle.param room and+ gone = Spindle.client_gone in
    Ok
      (fun send ->
        Spindle.Broadcast.subscribe hub ~topic:room () (fun sub ->
            Spindle.Broadcast.forward ~until:gone sub send))
    ]} *)

val body : string Dep.t
(** The body as it arrived: empty when there is none, {!Refusal.too_large} when
    there is too much. *)

val body_stream : ?content_types:string list -> unit -> Body.t Dep.t
(** The body, read as it arrives ({!Body}), up to the route's [max_body], or the
    server's where it gave none: for a body too large to hold, whose size a
    route that takes uploads gives in its limits ({!Route.Limits}).

    {[
    Spindle.post
      ~limits:(Spindle.Route.Limits.make ~max_body:(64 * 1024 * 1024) ())
      Path.(s "upload")
      (Returns.json receipt_json)
      (let+ body = Spindle.body_stream () in
       save body)
    ]}

    It is the one input read last, as {!body} is: once every dependency that
    needs no body has refused nothing. The route's handler reads it with
    {!Body.read} and has it only while it runs. Its bytes count toward the
    server's [body_budget] a part at a time, from the read that gets a part to
    the next, and it must keep arriving at the route's [min_body_rate], or the
    server's, over the whole body, measured only while the handler is inside a
    read. [content_types] are the types it takes, each [type/subtype], [type/*]
    or [type/*+suffix] -- any where none is named, and {!App.make} refuses one
    of none of these forms -- checked against the request's [Content-Type] in
    the first stage, as {!Dep.of_body}'s are, and listed as the request body's
    in the API's document.

    A route reads at most one body: one that lists this beside another
    [body_stream], {!body}, {!json} or an {!Dep.of_body} is refused when the app
    is made, because a body read as it arrives cannot also be read whole. *)

val multipart : ?max_head:int -> unit -> Multipart.t Dep.t
(** The body as a [multipart/form-data]'s parts, read a part at a time as they
    arrive ({!Multipart}): the upload {!body_stream} is for, already cut at its
    boundaries. It is {!body_stream} in all else -- the route's [max_body], its
    body rate over the whole body, the budget held a part at a time, the one
    body its route reads -- and [max_head] bounds each part's head, 16 KiB, as
    the server bounds a request's.

    {[
    Spindle.post
      ~limits:(Spindle.Route.Limits.make ~max_body:(4 * 1024 * 1024 * 1024) ())
      Path.(s "videos")
      (Returns.json receipt_json)
      (let+ parts = Spindle.multipart () in
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
    declares the code. Only a body has one: it is the route's own object,
    refused alone once every other input has passed, so a route may answer the
    code its own check answers -- one for a query it cannot use, however it is
    wrong -- where the inputs read before it are refused together, in one [400].
    [examples] are bodies it reads, for whoever documents the route.

    A request whose [Content-Type] names anything but [application/json] or an
    [application/...+json] is {!Refusal.unsupported_media_type}, before its body
    is read: a browser sends [text/plain] or a form from another site without
    asking first, and JSON only after a preflight, so accepting only JSON is
    what makes a forged request need permission it will not get. *)
