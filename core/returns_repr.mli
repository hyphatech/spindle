(** What a route returns: its model, what it describes, and how its result
    becomes a response. What {!Returns} is, underneath: a model is made only by
    {!Returns}. *)

(** A model, typed by what the route's handler answers. *)
type 'r t =
  | Json : {
      status : Spindle_http.Status.t;
      description : 'a Wiretype.t;
      examples : 'a list;
    }
      -> ('a, Refusal.t) result t
  | Json_response : {
      statuses : (Spindle_http.Status.t * string) list;
      description : 'a Wiretype.t;
      examples : 'a list;
    }
      -> (Spindle_http.Status.t * 'a, Refusal.t) result t
  | Html : (string, Refusal.t) result t
  | Text : (string, Refusal.t) result t
  | Empty : Spindle_http.Status.t -> (unit, Refusal.t) result t
  | Empty_response :
      (Spindle_http.Status.t * string) list
      -> (Spindle_http.Status.t, Refusal.t) result t
  | Response : (Response.t, Refusal.t) result t
  | Events : {
      declared : 's Event.declared list;
      keep_alive_s : float;
    }
      -> ('s Event.stream, Refusal.t) result t
  | Websocket : {
      protocol : ('c, 's) Spindle_http.Websocket.protocol;
      keep_alive_s : float option;
      max_message : int option;
    }
      -> ( ('c, 's) Spindle_http.Websocket.t ->
           (unit, Spindle_http.Websocket.error) result,
           Refusal.t )
         result
         t

(** What a model describes, its result type forgotten: what the document and the
    zod module read. *)
type shape =
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
  | Empty of Spindle_http.Status.t
  | Empty_response of (Spindle_http.Status.t * string) list
  | Response
  | Events : 's Event.declared list -> shape
  | Websocket : ('c, 's) Spindle_http.Websocket.protocol -> shape

val shape : 'r t -> shape

val upgrade : 'r t -> Request.t -> ((string * string) list, Refusal.t) result
(** For a WebSocket, RFC 6455 §4.2.1's handshake checked before the handler
    runs: the [101]'s fields, or why the request opens no socket. Nothing for
    any other model. *)

val respond :
  'r t ->
  pattern:string ->
  path:string ->
  upgrade:(string * string) list ->
  cookies:Cookie.t list ->
  headers:(string * string) list ->
  'r ->
  Response.t
(** The handler's result as a response: what the route set -- [cookies],
    [headers] -- goes with a success, never with a refusal. *)

val declares : shape -> Spindle_http.Status.t -> bool
(** Whether a model may answer a status: a route with one status sets it itself,
    so only a list is checked. *)
