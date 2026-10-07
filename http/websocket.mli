(** WebSockets, served and called, in one model: a protocol says what each side
    sends, and each end holds a socket typed from its own side.

    {[
    type said = { text : string } [@@deriving wiretype]

    let chat =
      Websocket.(protocol ~client:(json said_json) ~server:(json said_json) ())

    let echo =
      Spindle.get path (Returns.websocket chat)
        (Dep.return
           (Ok
              (fun ws ->
                let rec echo () =
                  let* said = Websocket.receive ws in
                  let* () = Websocket.send ws said in
                  echo ()
                in
                echo ())))

    let greet client =
      Spindle_client.websocket client chat "wss://example.com/echo" (fun ws ->
          let* () = Websocket.send ws { text = "hi" } in
          Websocket.receive ws)
    ]}

    The framework runs RFC 6455 whole -- the frames, their masks and fragments,
    ping and pong, keep-alive, the closing handshake -- and a handler only
    receives, sends and, if it wants to, closes. Every failure is a value: a
    handler returns a result, so a loop written with [let*] ends at the first
    thing that went wrong and says which, and how it ended decides the close.
    Nothing here raises into the application, and nothing cancels a handler
    whose socket has gone: it learns at its next [receive] or [send]. *)

(** {1 What a socket carries} *)

(** What travels one way, made by {!json}, {!text} or {!binary}; the
    constructors are for whatever describes a protocol, which reads them. *)
type 'a message = private
  | Json : 'a Wiretype.t -> 'a message  (** JSON of a description, as text *)
  | Text : string message  (** text as it is *)
  | Binary : string message  (** bytes as they are *)

val json : 'a Wiretype.t -> 'a message
val text : string message
val binary : string message

type ('c, 's) protocol
(** What a client sends, ['c], and what a server sends, ['s]. *)

val protocol :
  ?subprotocol:string ->
  client:'c message ->
  server:'s message ->
  unit ->
  ('c, 's) protocol
(** [subprotocol] is [Sec-WebSocket-Protocol], which both ends then insist on: a
    server refuses a client that did not offer it, and a client one that did not
    choose it. *)

val subprotocol : _ protocol -> string option
val client : ('c, _) protocol -> 'c message
val server : (_, 's) protocol -> 's message

(** {1 A socket} *)

type (!'i, !'o) t
(** An open socket, from one end: it receives ['i] and sends ['o]. A route's
    socket is [('c, 's) t], a caller's [('s, 'c) t]. It belongs to the fibers of
    the domain that runs it. *)

(** Why a socket is closed, as RFC 6455 §7.4 numbers them. *)
type close_code =
  | Normal  (** 1000 *)
  | Going_away  (** 1001: a server stopping, a page closed *)
  | Protocol_error  (** 1002 *)
  | Unsupported  (** 1003: a message of a kind this end does not take *)
  | Invalid_data  (** 1007: a message that could not be read *)
  | Policy  (** 1008 *)
  | Too_big  (** 1009 *)
  | Internal  (** 1011: our bug *)
  | Code of int
      (** any other a peer may send -- 1005 for a close that named none, 1010,
          1012 to 1014, and 3000 to 4999, the application's own *)

type error =
  | Closed of { code : close_code; reason : string }
      (** closed, by either end, with its code and reason *)
  | Lost of string
      (** the connection ended without a close, or went silent, or stopped
          taking what was written: in words for the log *)
  | Unreadable of string
      (** a message its description could not read, in words for the log; the
          socket is still open *)

val error_to_string : error -> string

val receive : ('i, _) t -> ('i, error) result
(** The next whole message, waiting for it. Once the socket has ended, its
    ending, every time. *)

val send : (_, 'o) t -> 'o -> (unit, error) result
(** Answers once the message is written. A value its own description cannot
    encode is our bug: logged as an error, and nothing is sent. *)

type 'o encoded
(** A message encoded once, to be sent to many sockets: what a
    [Spindle.Broadcast] of sockets carries, so the publisher renders once. *)

val encode : 'o message -> 'o -> 'o encoded
(** A value its own description cannot encode is our bug: logged as an error
    here, and the message sends nothing. *)

val send_encoded : (_, 'o) t -> 'o encoded -> (unit, error) result

val close : ?code:close_code -> ?reason:string -> _ t -> unit
(** Begins the closing handshake with [code] ([Normal]) and [reason] (none).
    What follows is read as ever, and {!receive} answers [Closed] once the peer
    has answered. A code no endpoint may send is our bug: logged, and the socket
    closed with [Internal]. So is a reason longer than 123 bytes or not UTF-8,
    which no close can carry (§5.5, §8.1): logged, and the close sent without
    it. *)

(** {1 Running one end}

    What [Spindle.Returns.websocket] and [Spindle_client.websocket] are built
    on, over a connection whose handshake is done. *)

val accept_key : string -> string
(** [Sec-WebSocket-Accept] for a [Sec-WebSocket-Key] (§4.2.2). *)

val run_server :
  ?keep_alive_s:float ->
  ?max_message:int ->
  ('c, 's) protocol ->
  Connection.t ->
  (('c, 's) t -> ('a, error) result) ->
  ('a, error) result

val run_client :
  ?keep_alive_s:float ->
  ?max_message:int ->
  mask:(unit -> string) ->
  ('c, 's) protocol ->
  Connection.t ->
  (('s, 'c) t -> ('a, error) result) ->
  ('a, error) result
(** [f]'s result, once the socket is closed. How it ended decides the close:
    [Ok] is [Normal], an [Unreadable] is [Invalid_data], and a socket already
    closed or lost has nothing left to close; a close sent waits a second for
    the peer's. [f] raising closes it with [Internal], and the raise goes on. A
    ping goes when nothing has been heard for [keep_alive_s] (15), and a peer
    silent for twice that is [Lost]; a message longer than [max_message] (1 MiB)
    closes it with [Too_big]. [mask] makes each frame's four bytes of masking,
    which must be unpredictable (§5.3); a mask of another length is our bug:
    logged, and the send answers [Lost]. *)
