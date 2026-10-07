(** What a handler answers.

    How an answer is framed, and whether its connection lasts, is the server's
    to say: [Content-Length], [Transfer-Encoding], [Connection], [Keep-Alive],
    [Upgrade], [TE] and [Trailer] are written by the server and by nothing else,
    because a length a handler wrote beside the server's is an answer a reader
    can take two ways. So are the fields the framework writes from what an
    answer carries -- [Content-Type] from [content_type], [Set-Cookie] from
    [cookies], [Date] and [X-Request-Id] -- because one written as a plain
    header beside them is a second answer to one question, and a cookie written
    that way would miss the [Secure] decision. An answer that sets any of them
    in [headers], or whose status is not a final one -- 200 to 599, with
    {!takeover}'s [101] the one exception -- is the route's bug: logged, and
    answered as {!Refusal.internal} instead. An answer after which the
    connection should end says so with {!close_connection}. *)

type t

type gone =
  | Gone
      (** What a stream's [send] answers once its client has gone, and every
          time after. *)

type stream = {
  produce : (string -> (unit, gone) result) -> (unit, gone) result;
  keep_alive : (float * string) option;
      (** [(s, filler)]: [filler] is written whenever nothing else has been for
          [s] seconds, so a quiet stream is not closed as idle by something in
          between *)
  length : int option;  (** how many bytes it sends, where that is known *)
}
(** A body written as it happens: see {!val-stream}. *)

type connection = Spindle_http.Connection.t = {
  reader : Eio.Buf_read.t;
  writer : Eio.Buf_write.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  send_timeout_s : float;
  stopping : unit Eio.Promise.t;
}
(** A connection once a protocol spoken after HTTP has it: see {!takeover}. The
    server's clock, the server's send limit, and resolved as the server begins
    to stop. *)

(** What follows the head. *)
type content =
  | Buffered of string  (** the whole body, its length known *)
  | Stream of stream
  | Takeover of { protocol : string; handle : connection -> unit }
      (** see {!takeover} *)

val make :
  ?status:Spindle_http.Status.t ->
  ?headers:(string * string) list ->
  ?cookies:Cookie.t list ->
  ?content_type:string ->
  string ->
  t
(** A body as it is. [status] defaults to [`OK] and [content_type] to
    [text/plain; charset=utf-8]. *)

val json :
  ?status:Spindle_http.Status.t ->
  ?headers:(string * string) list ->
  ?cookies:Cookie.t list ->
  'a Wiretype.t ->
  'a ->
  t
(** A value, encoded by its description. A value its own description cannot
    encode is our bug, and answers {!Refusal.internal}. *)

val html :
  ?status:Spindle_http.Status.t ->
  ?headers:(string * string) list ->
  ?cookies:Cookie.t list ->
  string ->
  t
(** A page, [text/html; charset=utf-8], as it is given: what {!Returns.html}
    answers, for a route that makes its own response. *)

val empty :
  ?status:Spindle_http.Status.t ->
  ?headers:(string * string) list ->
  ?cookies:Cookie.t list ->
  unit ->
  t
(** No body. [status] defaults to [`No_content]. *)

val redirect :
  ?status:Spindle_http.Status.t -> ?cookies:Cookie.t list -> string -> t
(** [status] defaults to [`Found]. *)

val stream :
  ?status:Spindle_http.Status.t ->
  ?headers:(string * string) list ->
  ?cookies:Cookie.t list ->
  ?content_type:string ->
  ?length:int ->
  ((string -> (unit, gone) result) -> (unit, gone) result) ->
  t
(** A body written as it happens: [produce send] is run once the head has gone,
    and every [send s] reaches the client before it answers [Ok ()]. Once the
    client has gone [send] answers [Error Gone], so a loop written with [let*]
    ends there. The response is over when [produce] returns.

    [length] is how many bytes it will send, for a body whose size is known
    before it is read -- a file. The server frames it with [Content-Length]
    rather than chunks, so a client can say how far along it is, and never
    writes past it: a stream that sends more is cut at [length], its [send]
    answering [Error Gone], and one that sends more or fewer has its connection
    closed after it, with an error in the log, since a length the body disagrees
    with is the next request's first bytes. *)

val events :
  ?headers:(string * string) list ->
  ?keep_alive_s:float ->
  ((string -> (unit, gone) result) -> (unit, gone) result) ->
  t
(** {!val-stream}, as Server-Sent Events: [text/event-stream], and nothing
    between here and the browser allowed to hold on to it. What is sent is the
    events, already spelled; the framework writes the framing, and a
    [: keep-alive] comment whenever nothing has been sent for [keep_alive_s]
    (15) seconds. *)

val takeover :
  protocol:string ->
  ?headers:(string * string) list ->
  ?cookies:Cookie.t list ->
  (connection -> unit) ->
  t
(** The connection itself, once the head has gone: [101 Switching Protocols] to
    [protocol], which the server names in [Upgrade] with [Connection: upgrade]
    beside it, then [handle connection] owns both ends until it returns, and the
    connection is closed after it. This is what a protocol spoken after HTTP --
    a WebSocket -- is built on. RFC 9110 §7.8 lets a server switch only to a
    protocol the client offered in its own [Upgrade], and never an HTTP/1.0
    client: a takeover that does either is the route's bug, logged, and answered
    as {!Refusal.internal} instead. A taken-over connection still counts against
    the server's cap and is cancelled when the server stops, like any other; its
    reads are the route's to bound, since what it waits for is its own
    protocol's. [HEAD] is answered with the head alone, and the connection
    closed after it, as after any [101]. *)

val refusal : Refusal.t -> t
(** [{"error": code, "message": sentence}], and the refusal's headers. The
    detail is not in it. *)

val refusal_json : (string * string * Refusal.problem list) Wiretype.t
(** The body {!refusal} writes -- the code, the sentence and, when there are
    any, the problems -- for whoever describes the API: what it says a refusal
    is comes from here and nowhere else. *)

val add_headers : (string * string) list -> t -> t
(** These headers as well as the ones already there -- a stream's among them,
    since its head goes out before its body. *)

val add_cookies : Cookie.t list -> t -> t
(** These cookies as well as the ones already there. *)

val close_connection : t -> t
(** The same answer, as its connection's last: the server says
    [Connection: close] and closes the connection once it has gone. *)

val closes_connection : t -> bool
(** Whether {!close_connection} made it its connection's last. *)

val status : t -> Spindle_http.Status.t

val headers : t -> (string * string) list
(** The answer's own; the content type and the cookies are not among them. *)

val content_type : t -> string option
(** None for an answer with no body to type: {!empty}, {!redirect}, {!takeover}.
*)

val cookies : t -> Cookie.t list
val content : t -> content

val refused : t -> Refusal.t option
(** The refusal this response was made from, for whoever logs it. *)
