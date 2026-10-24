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
    lent; a socket with no descriptor beneath it, such as a mock network's,
    cannot be watched and is closed after its call instead. A call never waits
    for a connection -- past the ones kept it opens its own -- because waiting
    would make one call's latency another's, and how many calls run at once is
    the caller's to limit. A new connection is opened through [net]: it tries
    each address the host's name resolves to there, in the order the resolver
    gives them, until one connects.

    A call has a deadline, which covers all of it -- the name's lookup included,
    which one fiber of the client's, on [sw], runs for every domain, so a lookup
    the system will not cancel is left to end in the background -- and one whose
    deadline passes closes its connection rather than give it back. A request is
    sent a second time only where that cannot be wrong: one that could not be
    written on a kept connection, and one that means the same done twice --
    [GET], [HEAD], [PUT], [DELETE], [OPTIONS], [TRACE] -- that met a kept
    connection's end before a byte of its answer. A [POST] that went out is
    never sent twice; it fails, and the caller decides: an error says whether
    the request went out, [`Unsent] or [`Lost], since only one that did not can
    be sent again blind.

    HTTPS is TLS against the system's certificates, set up once per client. A
    machine with no usable trust store cannot verify anybody, and the honest
    answer is that the call cannot be made, not that it is trusted anyway:
    [`Unsent], on every https call, and plain http unaffected.

    Cancellation is never an error here. It is how Eio stops work nobody is
    waiting for, and it passes through. *)

type t

val create :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  ?timeout:Mtime.Span.t ->
  ?max_body:int ->
  ?per_host:int ->
  ?idle_timeout:Mtime.Span.t ->
  ?authenticator:X509.Authenticator.t ->
  unit ->
  t
(** [sw] is the application's and never a request's: where the domain that made
    the client keeps its connections outside any server. [timeout] (30 s) is
    every call's deadline unless the call names its own, measured on
    [mono_clock], which is monotonic so that a wall clock that jumps moves no
    deadline; [max_body] (16 MiB) is the longest answer read. [per_host] (4)
    bounds the idle connections each domain keeps for one scheme, host and port
    -- never how many calls run at once -- and [idle_timeout] (15 s) retires one
    unused that long, or a second before the server's [Keep-Alive: timeout=]
    where it said less, and keeps none where it said a second or less: well
    inside common servers' own idle limits, so a server closing in the instant a
    request is written is rare. [authenticator] is what a server's certificate
    is checked against, the system's trust store unless given: a test gives one
    that trusts a certificate it made. *)

val run :
  ?timeout:Mtime.Span.t ->
  ?max_body:int ->
  ?per_host:int ->
  ?idle_timeout:Mtime.Span.t ->
  ?authenticator:X509.Authenticator.t ->
  < net : _ Eio.Net.t ; mono_clock : _ Eio.Time.Mono.t ; .. > ->
  (t -> 'a) ->
  'a
(** [run env f]: a client for as long as [f] runs, the network and the monotonic
    clock taken from [env], Eio's environment or anything that has them, and
    every connection it kept closed when [f] returns -- a program whose job is
    calling out:

    {[
    let () =
      Eio_main.run @@ fun env ->
      Spindle_client.run env @@ fun client -> ...
    ]}

    Each argument is {!create}'s, of the same name and default. A client that
    lives beside a server, for as long as the program does, is made with
    {!create} on the program's own switch. *)

type 'body response = {
  status : Spindle_http.Status.t;
  headers : (string * string) list;  (** names lower-cased *)
  body : 'body;
      (** the whole of it, a [string], from {!call}; a {!Body.t} to read as it
          arrives, from {!stream} *)
}
(** A response, its body's type saying how it arrived, so what reads its status
    and headers reads either. *)

type error =
  [ `Unsent of string
    (** the request did not go out whole, so the server cannot have acted on it
        and it may be sent again: a URL with no host, or a scheme other than
        [http] and [https]; a host with no address, or none of whose addresses
        connects; no usable trust store, an [https] host that is neither a name
        nor an address, or a TLS handshake that failed; a request target or
        field that cannot be written, or a field the client writes itself; and a
        request the connection would not take. In words for the log. *)
  | `Lost of string
    (** the request may have gone out and no whole answer came back, so the
        server may have acted on it and it is never sent again blind: the
        deadline passing, before the request went out or after -- its words say
        which deadline; the connection closing or failing before the answer
        ended; an answer that cannot be read, whose length cannot be told, that
        is cut short or is longer than [max_body], or an event longer than it;
        and, for a WebSocket, a [101] that does not accept the handshake. In
        words for the log. *) ]
(** The words every Hypha library uses for what happened to the work, so a
    handler's one [let*] runs over a call here and a statement there. *)

val error_to_string : [< error ] -> string

val call :
  t ->
  ?timeout:Mtime.Span.t ->
  ?headers:(string * string) list ->
  ?body:string ->
  Spindle_http.Meth.t ->
  string ->
  (string response, [> error ]) result
(** [call t meth url]. Any status is an answer: what a [4xx] means is the
    caller's to say. The URL's path and query are sent byte for byte as it wrote
    them, so a signed URL arrives as it was signed, and its fragment is not
    sent. One [debug] line per call on [spindle-client] -- the method, the host,
    the status, whether the connection was new or kept, and how long it took,
    and never a header or a body, because they are where a credential travels.
*)

(** {1 An answer read as it arrives} *)

(** An answer's body, read a piece at a time. *)
module Body : sig
  type t

  val read : t -> ([ `Data of string | `End ], [> error ]) result
  (** The next piece as it arrived, or its end. Each read waits at most the
      call's [read_timeout]; a read after one that failed answers that failure
      again, since a read cut off leaves a TLS connection unreadable; and a read
      after the function it was handed to has returned is [`End]. *)
end

val stream :
  t ->
  ?timeout:Mtime.Span.t ->
  ?read_timeout:Mtime.Span.t ->
  ?headers:(string * string) list ->
  ?body:string ->
  Spindle_http.Meth.t ->
  string ->
  (Body.t response -> 'a) ->
  ('a, [> error ]) result
(** [stream t meth url f]: [f] handed the answer as its head arrives, its body
    to read as it comes -- a model's streamed answer, a download too large to
    hold. [timeout] (the client's) bounds the head, and [read_timeout]
    ([timeout]) each wait for more of the body, never the whole, since a
    stream's length is its own. The connection is kept after [f] only when it
    read the body to its end and neither side said [close]; otherwise it is
    closed, which is how [f] stops a stream early. A request is sent again where
    {!call} would send it. *)

(** How an events stream ended. *)
type events_end =
  | Finished of string option
      (** the server ended it: the last event id it set, to carry on from *)
  | Stopped of string option  (** the function stopped it, at that id *)
  | Answered of string response
      (** the server answered with something other than a [200]
          [text/event-stream]: that answer, read whole *)

val events :
  t ->
  ?timeout:Mtime.Span.t ->
  ?read_timeout:Mtime.Span.t ->
  ?headers:(string * string) list ->
  ?last_event_id:string ->
  string ->
  (Spindle_http.Event_stream.event -> [ `Continue | `Stop ]) ->
  (events_end, [> error ]) result
(** [events t url f]: a [GET] asking for [text/event-stream] -- with
    [Last-Event-ID] where given one -- and each event handed to [f] as it
    arrives, read as the server wrote it ({!Spindle_http.Event_stream}), until
    the stream ends or [f] answers [`Stop]. Reconnecting is the caller's loop,
    from the id it answers. *)

(** {1 A WebSocket} *)

type websocket_error =
  [ error
  | `Not_upgraded of string response
    (** the server answered, without a [101] *)
  | Spindle_http.Websocket.error ]
(** A handshake that could not be made is a call's {!error}; how the socket
    ended is {!Spindle_http.Websocket.error}'s, whose [`Lost] is a call's too.
*)

val websocket_error_to_string : [< websocket_error ] -> string

val websocket :
  t ->
  ?timeout:Mtime.Span.t ->
  ?headers:(string * string) list ->
  ?keep_alive:Mtime.Span.t ->
  ?max_message:int ->
  ('c, 's) Spindle_http.Websocket.protocol ->
  string ->
  (('s, 'c) Spindle_http.Websocket.t ->
  ('a, ([> websocket_error ] as 'e)) result) ->
  ('a, 'e) result
(** [websocket t protocol url f] opens a socket to a [ws://] or [wss://] URL and
    runs [f] on it: the connection is [f]'s alone, never kept and never lent,
    opened for it and closed after it. [timeout] (the client's) bounds the
    handshake, and then how long a write may wait for the server to take
    anything; the handshake offers the protocol's name and insists on it, and
    checks that the answer proves it read this key. [headers] go beside the
    handshake's, which are the client's own. Masking keys come from the
    generator the TLS stack is seeded with. The socket gets one line in the log
    when it ends -- where it went, how long it lived and how, at [warn] when it
    never opened or did not end cleanly, and at [error] with what was raised and
    where when [f] raised, which goes on -- and never its query, where a
    credential travels. What [f] returns is
    {!Spindle_http.Private.Websocket.run_client}'s, and so are [keep_alive] and
    [max_message]: [f] may end with a failure of its own beside the socket's --
    a statement's, say -- which closes the socket as [Internal] and is answered
    as it is. *)

(** {1 OAuth} *)

(** What a resource server needs of its authorization server, found as RFC 8414
    says. *)
module Oauth : sig
  type keys = kid:string option -> Spindle_http.Jwk.t list
  (** The issuer's keys, as [Spindle.Bearer.keys] reads them. *)

  val keys : t -> issuer:string -> keys
  (** [keys client ~issuer]: the keys [issuer] signs its tokens with, from its
      metadata's [jwks_uri]. The metadata is the first found of
      [/.well-known/oauth-authorization-server] and then
      [/.well-known/openid-configuration] put before the issuer's path (RFC 8414
      §3.1), and [openid-configuration] after it (OpenID Connect Discovery §4),
      in the order MCP gives, and is used only where its [issuer] is [issuer]
      exactly (RFC 8414 §3.3).

      They are fetched when first asked for and kept. A [kid] the kept keys do
      not have fetches them again, at most once a minute -- so a key the issuer
      rotated in is found, and tokens naming keys nobody has cost one fetch a
      minute -- and so does none kept at all. A fetch that fails is a [warn]
      line, and the kept keys go on answering: none before one succeeds, so
      every token is refused until then. Each call answers the keys of the [kid]
      named, or every key where it names none. *)

  (** {1 Signing in}

      What a client of a protected resource needs: the authorization server
      found from the resource (RFC 9728) and its own metadata (RFC 8414, OpenID
      Connect Discovery), a person signed in through their browser by the
      authorization code grant with PKCE [S256] (RFC 7636), the token asked for
      that resource alone (RFC 8707), the answer checked to come from that
      server (RFC 9207), and the token refreshed as it expires.

      {[
      let oauth =
        Spindle_client.Oauth.create client ~clock:(Eio.Stdenv.clock env)
          ~metadata_document:"https://app.example.com/oauth/client.json"
          ~authorize:(fun url -> open_in_browser url)
      ]} *)

  type registration = {
    issuer : string;  (** the authorization server it was registered with *)
    client_id : string;
    secret : string option;  (** a confidential client's *)
  }
  (** A client registered beforehand with one authorization server, and used
      with that one alone. *)

  type tokens = {
    issuer : string;  (** who issued them *)
    access : string;
    refresh : string option;
    expires : Ptime.t option;
    scopes : string list;
  }

  type store = {
    find : resource:string -> tokens option;
    keep : resource:string -> tokens -> unit;
  }
  (** Where tokens are kept, by the resource they are for -- a keychain, a file
      the program owns. The library writes none itself. *)

  val in_memory : unit -> store
  (** Tokens kept for as long as the program runs. *)

  type oauth
  (** A client signing people in. *)

  type nonrec error =
    [ error
    | `Oauth of string
      (** signing in failed: a resource or an authorization server whose
          metadata could not be found or does not check, no way to identify this
          client to it, an answer that is not its own, or its refusal; in words,
          quoting no token *) ]

  val error_to_string : [< error ] -> string

  val create :
    ?registered:registration list ->
    ?metadata_document:string ->
    ?store:store ->
    ?wait:Mtime.Span.t ->
    clock:_ Eio.Time.clock ->
    authorize:(string -> unit) ->
    t ->
    oauth
  (** [authorize] is given the URL a person signs in at, and opens it in their
      browser. The browser is sent back to [http://127.0.0.1:<port>/callback], a
      port the system gives, which this client listens on while it waits, at
      most [wait] (5 min) for the person (RFC 8252 §7.3).

      This client is identified to an authorization server by its [registered]
      id for that server where there is one, and otherwise by
      [metadata_document], the HTTPS URL of a Client ID Metadata Document, where
      the server says it reads them, as MCP orders them. [store] ({!in_memory})
      keeps the tokens. [clock] says when one expires.

      Raises [Invalid_argument] for a [metadata_document] that is no https URL
      with a path: a constant written in source. *)

  val access : oauth -> resource:string -> (string option, [> error ]) result
  (** The access token kept for [resource], refreshed first where it expires
      within a minute and a refresh token was kept; [None] where none is kept,
      or one that cannot be refreshed. *)

  val sign_in :
    oauth ->
    resource:string ->
    ?metadata:string ->
    ?scopes:string list ->
    unit ->
    (tokens, [> error ]) result
  (** Signs a person in for [resource] -- the URL a request was made to -- and
      keeps the tokens. The resource's metadata is read from [metadata], the URL
      a [401]'s challenge named, or else from its well-known URL with the
      resource's path, then without (RFC 9728 §3.1, as MCP orders them), and
      used only where it names [resource] (§3.3). Its first authorization server
      this client can identify itself to is asked for [scopes] and those of the
      tokens kept for [resource], so a step up for one more scope keeps the
      others (as MCP asks), or else the metadata's [scopes_supported]. *)
end

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
