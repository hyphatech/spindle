(** Calling another server.

    The request is written, and the response read, by [spindle_http] -- the
    reader and writer the server is built on, so the framework has one account
    of where a message ends. A 1xx before the answer is read and dropped, a
    response cut short or framed two ways is an error, and a TLS connection is
    ended with its closure alert.

    Connections are the client's and never a caller's: a connection borrowed
    under a request's switch would be tied to that request -- under a server, to
    a browser's keep-alive. They are kept {b per domain}: a call borrows only a
    connection its own domain kept, on that domain's switch
    ({!Spindle_http.Local}), or on the client's own on the domain that made it,
    so a domain's calls never wait for another's; a call on a domain with
    neither closes its connection after it. A call borrows a kept connection or
    opens one, and gives it back only when the answer was read to its end and
    neither side said [close]; a kept one is watched while it waits, so a
    connection the server closed, or sent anything on, is retired rather than
    lent. A call never waits for a connection -- past the ones kept it opens its
    own -- because waiting would make one call's latency another's, and how many
    calls run at once is the caller's to limit. A new connection tries each
    address the host's name has, in the order the resolver gives them, until one
    connects.

    A call has a deadline, which covers all of it, and one whose deadline passes
    closes its connection rather than give it back. A request is sent a second
    time only where that cannot be wrong: one that could not be written on a
    kept connection, and one that means the same done twice -- [GET], [HEAD],
    [PUT], [DELETE], [OPTIONS] -- that met a kept connection's end before a byte
    of its answer. A [POST] that went out is never sent twice; it fails, and the
    caller decides.

    HTTPS is TLS against the system's certificates, set up once per client. A
    machine with no usable trust store cannot verify anybody, and the honest
    answer is that the call cannot be made, not that it is trusted anyway:
    {!Unreachable}, on every https call, and plain http unaffected.

    Cancellation is never an error here. It is how Eio stops work nobody is
    waiting for, and it passes through. *)

type t

val create :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  ?timeout_s:float ->
  ?max_body:int ->
  ?per_host:int ->
  ?idle_s:float ->
  ?authenticator:X509.Authenticator.t ->
  unit ->
  t
(** [sw] is the application's and never a request's: where the domain that made
    the client keeps its connections outside any server. [timeout_s] (30) is
    every call's deadline unless the call names its own, measured on
    [mono_clock], which is monotonic so that a wall clock that jumps moves no
    deadline; [max_body] (16 MiB) is the longest answer read. [per_host] (4)
    bounds the idle connections each domain keeps for one scheme, host and port
    -- never how many calls run at once -- and [idle_s] (15) retires one unused
    that long, or a second before the server's [Keep-Alive: timeout=] where it
    said less, and keeps none where it said a second or less: well inside common
    servers' own idle limits, so a server closing in the instant a request is
    written is rare. [authenticator] is what a server's certificate is checked
    against, the system's trust store unless given: a test gives one that trusts
    a certificate it made. *)

val run :
  ?timeout_s:float ->
  ?max_body:int ->
  ?per_host:int ->
  ?idle_s:float ->
  ?authenticator:X509.Authenticator.t ->
  Eio_unix.Stdenv.base ->
  (t -> 'a) ->
  'a
(** [run env f]: a client for as long as [f] runs, everything taken from Eio's
    environment, and every connection it kept closed when [f] returns -- a
    program whose job is calling out:

    {[
    let () =
      Eio_main.run @@ fun env ->
      Spindle_client.run env @@ fun client -> ...
    ]}

    Each argument is {!create}'s, of the same name and default. A client that
    lives beside a server, for as long as the program does, is made with
    {!create} on the program's own switch. *)

type response = {
  status : int;
  headers : (string * string) list;  (** names lower-cased *)
  body : string;
}

type error =
  | Unreachable of string
      (** the call could not be made, or its answer not read, in words for the
          log: a URL with no host, or a scheme other than [http] and [https]; a
          host with no address, or none of whose addresses connects; no usable
          trust store, an [https] host that is neither a name nor an address, or
          a TLS handshake or alert that failed; a request target or field that
          cannot be written, or a field the client writes itself; a response
          that cannot be read, whose length cannot be told, that is cut short or
          is longer than [max_body], or an event longer than it; and the
          connection failing or closing under the call *)
  | Timed_out of float  (** the deadline, in seconds, that passed *)

val error_to_string : error -> string

val call :
  t ->
  ?timeout_s:float ->
  ?headers:(string * string) list ->
  ?body:string ->
  Spindle_http.Meth.t ->
  string ->
  (response, error) result
(** [call t meth url]. Any status is an answer: what a [4xx] means is the
    caller's to say. One [debug] line per call on [spindle.client] -- the
    method, the host, the status, whether the connection was new or kept, and
    how long it took, and never a header or a body, because they are where a
    credential travels. *)

(** {1 An answer read as it arrives} *)

(** An answer's body, read a piece at a time. *)
module Body : sig
  type t

  val read : t -> ([ `Data of string | `End ], error) result
  (** The next piece as it arrived, or its end. Each read waits at most the
      call's [read_timeout_s]; a read after the function it was handed to has
      returned is [`End]. *)
end

type answer = { status : int; headers : (string * string) list; body : Body.t }
(** A response whose body is read as it arrives: headers lower-cased. *)

val stream :
  t ->
  ?timeout_s:float ->
  ?read_timeout_s:float ->
  ?headers:(string * string) list ->
  ?body:string ->
  Spindle_http.Meth.t ->
  string ->
  (answer -> 'a) ->
  ('a, error) result
(** [stream t meth url f]: [f] handed the answer as its head arrives, its body
    to read as it comes -- a model's streamed answer, a download too large to
    hold. [timeout_s] (the client's) bounds the head, and [read_timeout_s]
    ([timeout_s]) each wait for more of the body, never the whole, since a
    stream's length is its own. The connection is kept after [f] only when it
    read the body to its end and neither side said [close]; otherwise it is
    closed, which is how [f] stops a stream early. A request is sent again where
    {!call} would send it. *)

(** How an events stream ended. *)
type events_end =
  | Finished of string option
      (** the server ended it: the last event id it set, to carry on from *)
  | Stopped of string option  (** the function stopped it, at that id *)
  | Refused of response
      (** the answer was not a [200] [text/event-stream]: it, read whole *)

val events :
  t ->
  ?timeout_s:float ->
  ?read_timeout_s:float ->
  ?headers:(string * string) list ->
  ?last_event_id:string ->
  string ->
  (Spindle_http.Event_stream.event -> [ `Continue | `Stop ]) ->
  (events_end, error) result
(** [events t url f]: a [GET] asking for [text/event-stream] -- with
    [Last-Event-ID] where given one -- and each event handed to [f] as it
    arrives, read as the server wrote it ({!Spindle_http.Event_stream}), until
    the stream ends or [f] answers [`Stop]. Reconnecting is the caller's loop,
    from the id it answers. *)

(** {1 A WebSocket} *)

type websocket_error =
  | Failed of error  (** the handshake could not be made, as a call's *)
  | Refused of response  (** the server answered, without a [101] *)
  | Ended of Spindle_http.Websocket.error
      (** how the function's socket ended *)

val websocket_error_to_string : websocket_error -> string

val websocket :
  t ->
  ?timeout_s:float ->
  ?headers:(string * string) list ->
  ?keep_alive_s:float ->
  ?max_message:int ->
  ('c, 's) Spindle_http.Websocket.protocol ->
  string ->
  (('s, 'c) Spindle_http.Websocket.t ->
  ('a, Spindle_http.Websocket.error) result) ->
  ('a, websocket_error) result
(** [websocket t protocol url f] opens a socket to a [ws://] or [wss://] URL and
    runs [f] on it: the connection is [f]'s alone, never kept and never lent,
    opened for it and closed after it. [timeout_s] (the client's) bounds the
    handshake, and then how long a write may wait for the server to take
    anything; the handshake offers the protocol's name and insists on it, and
    checks that the answer proves it read this key. [headers] go beside the
    handshake's, which are the client's own. Masking keys come from the
    generator the TLS stack is seeded with. The socket gets one line in the log
    when it ends -- where it went, how long it lived and how, at [warn] when it
    never opened or did not end cleanly -- and never its query, where a
    credential travels. What [f] returns is
    {!Spindle_http.Websocket.run_client}'s, and so are [keep_alive_s] and
    [max_message]. *)

(** {1 Spans, sent to a collector} *)

(** OTLP over HTTP, as JSON: what an OpenTelemetry Collector reads at
    [/v1/traces] with no protocol buffers. *)
module Otlp : sig
  val run :
    ?ratio:float ->
    ?headers:(string * string) list ->
    clock:_ Eio.Time.clock ->
    endpoint:string ->
    service:string ->
    t ->
    (Spindle_http.Trace.exporter -> 'a) ->
    'a
  (** [run ~clock ~endpoint ~service client f]: an exporter for as long as [f]
      runs, sending through [client] to [endpoint]'s [/v1/traces] -- the
      Collector's base URL, [http://collector:4318] -- every five seconds, or as
      soon as 512 spans wait, and what is left when [f] returns:

      {[
      Spindle_client.Otlp.run ~clock:(Eio.Stdenv.clock env)
        ~endpoint:"http://collector:4318" ~service:"app" client
      @@ fun trace -> Spindle.serve env ~trace routes
      ]}

      [service] is the [service.name] every span is under; [headers] go with
      every post, a collector's credential among them; [ratio] is
      {!Spindle_http.Trace.val-exporter}'s. Made where the program starts and no
      request is, since its posts are calls and a call in a trace is a span:
      from there they are in none, and record nothing.

      At most 2048 spans wait. One ending past that is dropped, and so is a
      batch the collector refused or never answered; each is a [warn] line
      saying how many. *)
end
