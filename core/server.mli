(** Serving an {!App}: the connection loop.

    The loop is Spindle's own, and so is every byte it reads and writes. Every
    decision about a connection is made here: where a head and a body end,
    whether a connection carries another request, and how long anything may
    take. *)

type proxy_header = Request.proxy_header =
  | X_forwarded_for
  | Forwarded  (** which forwarding header a trusted proxy writes *)

val run :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  now:(unit -> int) ->
  domain_mgr:_ Eio.Domain_manager.t ->
  ?domains:int ->
  port:int ->
  ?host:string ->
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
  ?proxy_header:proxy_header ->
  ?backlog:int ->
  ?max_connections:int ->
  ?stop:unit Eio.Promise.t ->
  ?drain_s:float ->
  ?on_stop:(unit -> unit) ->
  ?ready:(string -> unit) ->
  ?trace:Spindle_http.Trace.exporter ->
  ?metrics:Metrics.t ->
  App.t ->
  unit
(** Serves on [host] and [port], as a name or an address: [localhost] (the
    default), an address such as ["10.0.0.5"] or ["::1"], a wildcard, or a name
    the resolver knows, every address of which is bound. [ready] is told what is
    listening.

    [localhost] is both loopback addresses, [127.0.0.1] and [[::1]], whatever
    the resolver says: clients commonly prefer the IPv6 answer, so an IPv4-only
    socket is a browser's bare network error while [curl] still works. A
    wildcard, ["0.0.0.0"] or ["::"], is every interface of both families -- what
    a container, a pod or a hosting platform needs -- and binds the IPv6
    wildcard, which on most hosts takes IPv4 as well, with the IPv4 wildcard
    beside it where it does not. A host with no IPv6 is served on IPv4 alone. A
    name the resolver knows nothing of raises Eio's I/O error before anything
    listens, as a port in use does.

    [localhost] is the default so that listening beyond this machine is written
    down where the server starts, and a laptop never serves the network it
    happens to be on. The limits below hold with no proxy in front at all; TLS
    is the one thing left to one, or to the platform.

    {b Domains.} Connections are served on [domains] domains --
    [Domain.recommended_domain_count ()] unless told, every core the machine has
    -- the calling one and the rest started through [domain_mgr]. A connection
    lives on the domain that accepted it, for all its life; a busy domain
    accepts less, which is the balance there is. Every limit below is one limit
    across all of them. A handler therefore runs beside handlers on other
    domains: whatever it touches is immutable after startup, or safe from any
    domain -- an [Atomic], an [Eio.Mutex], an [Eio.Stream] -- and work that
    outlives it is forked onto its own domain's switch ({!Local},
    {!Background}). An application whose state is not is served with
    [~domains:1] and says why. Each serving domain's minor heap is raised to a
    million words (8 MB) unless it is already larger, so the requests in flight
    are collected young rather than promoted; [OCAMLRUNPARAM]'s [s] asks for
    more.

    [now] is the application's clock, in epoch milliseconds, and the only one a
    handler sees. [mono_clock] measures every duration the server keeps or
    reports -- the timeouts, the drain and the access log's [ms] -- and is
    monotonic, so a wall clock that jumps moves none of them.

    {b Bodies.} A body longer than [max_body] (1 MiB) is [413] -- a chunked
    body's extensions count toward it -- and a declared length past it is
    refused before a client that asked is told to send it. The bodies being held
    at once share [body_budget] (64 MiB), counted as their bytes arrive rather
    than as their lengths claim, and given back when the route returns, before
    its answer is written: one that does not fit is [503 busy] and its
    connection closed, which is what bounds the memory a route that accepts
    anonymous bodies can be made to hold. A body is read only if the route needs
    it. Whatever a route left unread is read and dropped, up to [discard_limit]
    (64 KiB), before the answer is written; a body with more left than that
    closes the connection instead, because a new connection costs less than
    reading what nobody wants.

    {b Heads.} A request head larger than [max_header_bytes] (16 KiB) is [431],
    or [414] when it is the request line that does not fit; one that takes
    longer than [head_timeout_s] (10) to arrive is [408]; an HTTP/1.1 request
    without exactly one [Host] is [400]; and a head whose framing RFC 9112
    forbids -- a [Transfer-Encoding] beside a [Content-Length], two different
    lengths, a coding that is not [chunked] -- is [400]; each is closed. A
    connection with no request for [idle_timeout_s] (60) is closed.

    {b Waiting.} A connection has one deadline, moved as it makes progress, and
    every wait on the client runs against it: between requests, [idle_timeout_s]
    from the last answer; for a head, [head_timeout_s] from its first byte; for
    a body, [body_timeout_s] (20) from when it is first read, moved a second
    later for every [min_body_rate] (500) bytes that arrive -- what came in with
    the head included -- so a body must keep up that rate once its allowance is
    spent, and a byte just inside every wait cannot hold a connection for as
    long as its length allows. The figures are a floor no ordinary upload is
    near: a megabyte at the floor still arrives in about half an hour. A body
    that falls behind is unreadable, and its connection closed after the answer;
    holding a slot then costs bandwidth rather than nothing, and an address that
    pays it is the per-address limit's to stop, which is a proxy's.

    {b Answers.} Every 2xx, 3xx and 4xx carries [Date], from [now]. A write the
    client does not read for [send_timeout_s] (30) -- a head, a body, a stream's
    event -- closes the connection, and a stream ends as its client having
    stopped reading: a client that never reads would otherwise hold a fiber and
    a connection slot for as long as the process lives. A takeover's writes are
    the route's own ({!Response.takeover}).

    {b HTTP/1.0.} A client speaking it is answered as RFC 9112 asks of one: a
    stream is written as it happens and ended by closing the connection, since
    HTTP/1.0 has no chunked coding; it is sent no [100 Continue]; and a request
    of its that carries [Transfer-Encoding] is answered and then closed, since
    whoever framed it cannot be trusted to have ended it where it ends.

    {b Connections.} A connection carries another request only when the request
    asked for it, its body was read to the end, the server is not stopping and
    the answer did not say [Connection: close]; otherwise the server closes it
    itself, in stages: its own side first, then what the client is still sending
    read and dropped -- up to [discard_limit], for at most [linger_s] (1) -- and
    then the socket, so the answer is not lost to the reset a closed socket
    answers unread bytes with. [max_connections] (512) is how many connections
    each address holds at once; past it the kernel's [backlog] (128) keeps the
    rest waiting; every domain accepts on every address, and the cap is the
    address's, not a domain's. Keep it under the process's descriptor limit: the
    cap is what keeps [accept] from failing at that limit, a failure that would
    otherwise cancel every open connection.

    {b Stopping.} Without [stop], serves until the switch is cancelled. When
    [stop] resolves: [on_stop ()] runs -- where the application ends its
    streams, since a stream never ends on its own -- the addresses stop
    accepting, the requests being answered get [drain_s] (10) seconds to finish
    and each answer says [Connection: close], and then whatever is left, on
    every domain, is cancelled and [run] returns. The drain counts requests, not
    connections, so a proxy's idle connections do not hold it open. See
    {!stop_on_signals}.

    Every request gets an id, answered in [x-request-id] and carried by every
    line logged while it is handled, and one [info] line when it is answered.
    With [trace], it is a span too ({!Spindle_http.Trace}): a [Server] span
    named by its method and route -- [GET /users/{id}], or the method alone
    where no route answered -- with the access line's fields but its duration,
    which is the span's own, and failed by a [5xx]. With [metrics], it is
    counted, and so are the connections and the body budget ({!Metrics}).
    [trusted_proxies] are the peers whose [X-Request-Id] and forwarding header
    are believed ({!Request.client}); there are none unless named.
    [proxy_header] is the forwarding header they write, [X_forwarded_for] unless
    given, and the only one read: a proxy that writes one and passes the other
    through from the client would otherwise let the client choose its own
    address. Each is an address, a range of them in CIDR notation ([10.0.0.0/8],
    [fd00::/8]) -- a fleet of proxies behind a load balancer being one entry --
    or a Unix peer as it is printed ([unix:<path>]). An IPv4 peer reached
    through the IPv6 wildcard is its IPv4 address, so a proxy named by one is
    trusted through the other.

    {b Raises} [Invalid_argument], before anything listens, for a limit out of
    its range -- fewer than one domain, connection, header byte or byte a
    second; a negative size; a time that is not finite, or not above zero, but
    for [linger_s] and [drain_s], which may be zero -- and for a trusted proxy
    that is no address, range or [unix:<path>]: each is a constant written where
    the server starts, and read as given it would serve nobody, or trust nobody,
    without a word. *)

val serve_on :
  mono_clock:_ Eio.Time.Mono.t ->
  now:(unit -> int) ->
  domain_mgr:_ Eio.Domain_manager.t ->
  ?domains:int ->
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
  ?proxy_header:proxy_header ->
  ?max_connections:int ->
  ?stop:unit Eio.Promise.t ->
  ?drain_s:float ->
  ?on_stop:(unit -> unit) ->
  ?trace:Spindle_http.Trace.exporter ->
  ?metrics:Metrics.t ->
  [> `Generic ] Eio.Net.listening_socket_ty Eio.Resource.t list ->
  App.t ->
  unit
(** {!run} on sockets the caller is already listening on -- a test's own, on a
    port the system chose -- with everything else exactly as {!run} does it. *)

val stop_on_signals : sw:Eio.Switch.t -> unit -> unit Eio.Promise.t
(** A promise resolved by the first SIGTERM or SIGINT, for {!run}'s [stop].
    Nothing installs a signal handler unless this is called; after the first
    signal both go back to their default, so a second one ends the process at
    once. *)
