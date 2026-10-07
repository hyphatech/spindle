(** What a route returns, declared where the route is: a page, text, a JSON
    value, nothing, a stream of events, or a response the endpoint makes itself.
    It decides what the route's list of inputs finally returns, so a route
    cannot return anything else, and it is known without running the route --
    which is how the API's document is written.

    {[
    Spindle.get Path.(s "users" / user_id) (Returns.json user_json)
      (let+ id = Spindle.param user_id in user_json id)

    Spindle.get Path.root Returns.text
      (Dep.return (Ok "Good morning."))

    Spindle.get Path.(s "events") (Returns.events Event.[ declare state ])
      (let+ ... in Ok (fun send -> ...))
    ]}

    The endpoint returns the plain value, or a {!Refusal}: an [Error] is the
    refusal's answer, and an [Ok] is the model's. A cookie or a header the
    endpoint sets goes with an [Ok] ({!Spindle.set_cookie},
    {!Spindle.add_header}). *)

type 'r t = 'r Returns_repr.t
(** A model whose route's inputs come to ['r]. *)

val json :
  ?status:Spindle_http.Status.t ->
  ?examples:'a list ->
  'a Wiretype.t ->
  ('a, Refusal.t) result t
(** A value, encoded by its description, with [status] ([`OK]). A value its own
    description cannot encode is our bug, and answers {!Refusal.internal}.
    [examples] are values it may return, for whoever documents the route. *)

val json_response :
  ?examples:'a list ->
  statuses:(Spindle_http.Status.t * string) list ->
  'a Wiretype.t ->
  (Spindle_http.Status.t * 'a, Refusal.t) result t
(** A value, as {!json}'s, under a status the endpoint chooses: for a route
    whose success is one of several things -- made or replaced, queued or done.
    [statuses] is each status it may answer and, in a sentence, when; the
    endpoint returns [Ok (`Created, v)], so every branch says which.

    {[
    Spindle.Returns.json_response user_json
      ~statuses:
        [ (`Created, "The user was made."); (`OK, "The user was replaced.") ]
    ]}

    A status is a success, [2xx]: failing is a refusal. An empty list, a status
    listed twice or one that is not a success is refused when the app is made. A
    status the endpoint answers that the list does not name is still sent, and
    is logged as the route's bug, which {!Test.call} raises on. *)

val html : (string, Refusal.t) result t
(** A page: [200], [text/html; charset=utf-8], written as the endpoint made it.
    Spindle has no template language: a page is whatever the application renders
    it with, and escaping what a person sent is that renderer's. *)

val text : (string, Refusal.t) result t
(** Text: [200], [text/plain; charset=utf-8]. *)

val empty : ?status:Spindle_http.Status.t -> unit -> (unit, Refusal.t) result t
(** No body, with [status] ([`No_content]): what a route answers when it did
    what it was asked and has nothing to say. The endpoint returns [Ok ()]. *)

val empty_response :
  statuses:(Spindle_http.Status.t * string) list ->
  (Spindle_http.Status.t, Refusal.t) result t
(** No body, under a status the endpoint chooses, as {!json_response} chooses
    one: the endpoint returns [Ok `Created] or [Ok `No_content]. *)

val response : (Response.t, Refusal.t) result t
(** A response the endpoint makes itself -- a redirect, a file, anything below
    the other models. What it holds is the endpoint's to say, and is described
    as no more than that. *)

val events :
  ?keep_alive_s:float ->
  's Event.declared list ->
  ('s Event.stream, Refusal.t) result t
(** A stream of Server-Sent Events of stream ['s], each a kind declared here:
    the endpoint's [send] takes no event of another stream, and one of this
    stream's left out of the list is sent and logged as the route's bug. A
    [: keep-alive] comment goes whenever nothing has been sent for
    [keep_alive_s] (15) seconds, so nothing in between closes a quiet stream as
    idle. A reconnecting browser's [Last-Event-ID] is an input like any header,
    [Spindle.Header.optional "last-event-id" codec]. *)

val websocket :
  ?keep_alive_s:float ->
  ?max_message:int ->
  ('c, 's) Spindle_http.Websocket.protocol ->
  ( ('c, 's) Spindle_http.Websocket.t ->
    (unit, Spindle_http.Websocket.error) result,
    Refusal.t )
  result
  t
(** A WebSocket speaking [protocol]: the endpoint answers [Ok handler], or a
    refusal before the upgrade. The handshake is checked before the endpoint
    runs: a request that opens no socket is {!Refusal.Code.upgrade_required}, a
    malformed one [invalid] at the header that is wrong, and one from another
    site's page [cross_origin], though it is a [GET]. The handler is
    {!Spindle_http.Websocket.run_server}'s, with [keep_alive_s] and
    [max_message] its own; the socket gets a log line when it ends. *)

(** What a route returns, for whatever describes it. *)
type shape = Returns_repr.shape =
  | Json : {
      status : Spindle_http.Status.t;
      description : 'a Wiretype.t;
      examples : 'a list;
    }
      -> shape
  | Json_response : {
      statuses : (Spindle_http.Status.t * string) list;
      description : 'a Wiretype.t;
      examples : 'a list;
    }
      -> shape
  | Html
  | Text
  | Empty of Spindle_http.Status.t  (** no body, with this status *)
  | Empty_response of (Spindle_http.Status.t * string) list
      (** no body, with one of these statuses *)
  | Response
  | Events : 's Event.declared list -> shape
  | Websocket : ('c, 's) Spindle_http.Websocket.protocol -> shape
