(** Calling an application in-process: no socket, no port, and a clock the test
    sets. *)

type response = {
  status : Spindle_http.Status.t;
      (** as {!Spindle_http.Status.of_int} spells it: [`Conflict], never
          [`Code 409] *)
  headers : (string * string) list;  (** [set-cookie] among them *)
  body : string;
}

val app :
  ?resources:Dep.resource list ->
  ?mono_clock:_ Eio.Time.Mono.t ->
  ?middleware:Middleware.t list ->
  ?refuses:Refusal.Code.t list ->
  ?not_found:(Response.t, Refusal.t) result Dep.t ->
  ?cors:Cors.t ->
  ?compress:Compress.t ->
  ?check_origin:bool ->
  ?trusted_origins:string list ->
  ?trailing_slash:App.trailing_slash ->
  ?keys:Key.ring ->
  Route.t list ->
  App.instance
(** [app routes]: {!App.make} and {!App.start}, for a test -- every argument
    theirs, of the same name and default -- an instance of its own, given
    [resources] as {!App.start} is ({!Dep.val-resource}), but only those the
    routes it calls read, and those the not-found answer reads: {!call} raises
    on a route that reads one it was not given. Its limits ({!Rate}) count from
    none, apart from any other app's, on [mono_clock]: one that never moves
    unless given, so a test that waits out a limit gives
    [Eio_mock.Clock.Mono.make ()] and moves it with
    [Eio_mock.Clock.Mono.set_time]. Raises [Invalid_argument] with {!App.make}'s
    reason for a table it refuses, as [Spindle.serve] does: a route table is a
    constant written in source, and a test that made a bad one has nothing to do
    but stop. A test of what {!App.make} refuses calls {!App.make}. It raises
    too for a {!Static.directory} or {!Files.directory} route, which reads a
    directory when the server starts and a test has none: a test loads one with
    {!Static.load} and serves it with {!Static.route}, or serves one it opened
    itself with {!Files.route}, as the message says. And it raises for
    [resources] {!App.start} refuses: one {!Dep.of_resource} did not make, or
    one given twice. *)

val call :
  ?now:Ptime.t ->
  ?peer:string ->
  ?proxied:bool ->
  ?proxy_header:Request.proxy_header ->
  ?version:Spindle_http.Version.t ->
  ?headers:(string * string) list ->
  ?body:string ->
  App.instance ->
  Spindle_http.Meth.t ->
  string ->
  response
(** [call app meth target]. [now] defaults to [Ptime.epoch] and [peer] to
    [127.0.0.1]; [proxied] says the peer is a proxy the server trusts
    ({!Request.proxied}), false unless given, and [proxy_header] which header it
    writes; [version] is the one the request is sent in, HTTP/1.1 unless given.

    The status and headers are exactly the ones the server would write for this
    request -- its length, its [x-request-id], its cookies as written for this
    request's [Host] (so a test that sends none is answered [Secure] ones) --
    save [connection], which belongs to a connection and there is none. A stream
    is run to its end and its body collected; a takeover's body is empty, since
    there is no connection to hand it.

    Raises [Invalid_argument] when the route read a resource {!app} was not
    given, naming it, and when the answer refused with a code that neither the
    matched route, nor any of its inputs, nor the app's [refuses], nor the
    framework declares, or answered a status its route's
    {!Returns.json_response} or {!Returns.empty_response} does not list
    ({!App.answered}): a test that reaches that answer has found a bug, which
    the server only logs. *)

(** {1 A browser} *)

(** Calls that keep what the app set, as a browser does. *)
module Browser : sig
  type t

  val call :
    ?now:Ptime.t ->
    ?peer:string ->
    ?headers:(string * string) list ->
    ?body:string ->
    t ->
    Spindle_http.Meth.t ->
    string ->
    response
  (** {!Test.call}'s, with the cookies the browser holds for the target's path
      sent -- longer paths first -- and every [Set-Cookie] of the answer kept:
      by name and path, the path the request's directory where it names none,
      and dropped by an empty value, a [Max-Age] of zero or less, or an age past
      a later call's [now]. [Secure] is not asked about, since a test has no
      scheme. *)

  val cookies : t -> (string * string) list
  (** What it holds, by name, in the order they were set. *)
end

val browser : App.instance -> Browser.t
(** A browser holding no cookie:

    {[
    let b = Spindle.Test.browser app in
    let _ = Spindle.Test.Browser.call b `POST "/sign-in" ~body in
    let me = Spindle.Test.Browser.call b `GET "/me" in ...
    ]} *)

(** {1 An events route} *)

val events :
  ?now:Ptime.t ->
  ?headers:(string * string) list ->
  App.instance ->
  string ->
  (Spindle_http.Event_stream.event -> [ `Continue | `Stop ]) ->
  (unit, response) result
(** [events app target f] runs the events route at [target] and hands each event
    -- its name, data and id, read as a client reads it
    ({!Spindle_http.Event_stream}) -- to [f], until the stream ends or [f]
    answers [`Stop]: a stream that never ends can be read three events of and
    left. Stopping is the client going, so the route's next [send] is
    [Error Gone] and {!Spindle.client_gone} is resolved, and a producer waiting
    for something to send is cancelled rather than waited on. [Error] is the
    answer where the route answered without a stream. It runs inside
    [Eio_main.run], as {!websocket} does. Raises as {!call} does, for a refusal
    nothing declares, and for an event longer than a reader holds (1 MiB): the
    route's bug, in a test. *)

type websocket_error =
  | Refused of response  (** the route answered without a [101] *)
  | Ended of Spindle_http.Websocket.error
      (** how the function's socket ended *)

val websocket_error_to_string : websocket_error -> string

val websocket :
  ?now:Ptime.t ->
  ?headers:(string * string) list ->
  App.instance ->
  ('c, 's) Spindle_http.Websocket.protocol ->
  string ->
  (('s, 'c) Spindle_http.Websocket.t ->
  ('a, Spindle_http.Websocket.error) result) ->
  ('a, websocket_error) result
(** [websocket app protocol target f] opens a socket to the route at [target],
    as a browser does, and runs [f] on the caller's end while the route's
    handler runs on the other, over a pair of sockets and no port. [headers]
    come before the handshake's own, so an [Origin] is one of them. A route that
    refuses the upgrade answers {!Refused}, with the answer {!call} would have
    had. Each end's clock never moves, so no keep-alive or limit fires. It runs
    inside [Eio_main.run], since a socket is fibers. Raises as {!call} does, for
    a refusal nothing declares. *)

val header : response -> string -> string option
