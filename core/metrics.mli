(** What a server counts, read as Prometheus reads it: counters, gauges and
    histograms, each with a fixed list of label names, registered on a registry
    the application makes and passes where it serves --

    {[
    let metrics = Spindle.Metrics.create () in
    Spindle_postgres.Pool.run env db @@ fun pool ->
    Spindle_postgres.Pool.measure pool metrics;
    Spindle.serve env ~metrics (routes @ Spindle.Metrics.routes metrics)
    ]}

    {b Counting never contends.} Each series keeps a cell per domain, which only
    that domain's work adds to, found through a table of the domain's own; they
    are summed when the metrics are read. A domain takes a family's lock only
    the first time it counts a combination of label values.

    {b A name is OpenTelemetry's}, dotted, as a label's is --
    [http.server.request.duration], [http.route] -- and is exposed in
    Prometheus's spelling: dots as underscores, the [unit] after, and a
    counter's [_total] -- [http_server_request_duration_seconds]. A name, a
    label or a list of buckets that cannot be exposed, and a name registered
    twice, raise [Invalid_argument] where it is registered, since each is a
    constant written in source; so does counting with a number of label values
    other than the family's, or adding less than nothing to a counter, which
    Prometheus would read as the process restarting.

    {b A label's value is the program's, never a request's}: a route and never a
    path, a method HTTP names and never another, since every value is a series
    kept for as long as the process lives. An empty value is left out of the
    series, as Prometheus reads it. *)

type t
(** A registry. *)

val create : unit -> t

(** {1 Counters} *)

type counter

val counter :
  t -> ?help:string -> ?unit:string -> ?labels:string list -> string -> counter
(** [counter t name]: a count that only goes up, exposed with [_total]. [unit]
    is a Prometheus unit word -- [seconds], [bytes] -- and [labels] the names of
    its labels, none unless given. *)

val inc : ?by:int -> counter -> string list -> unit
(** [inc c values]: add [by] (1) to the series of those label values, in the
    order of the family's names. *)

(** {1 Gauges} *)

type gauge

val gauge :
  t -> ?help:string -> ?unit:string -> ?labels:string list -> string -> gauge
(** A value that goes up and down: what is open, what is in flight. *)

val add : gauge -> string list -> int -> unit
(** [add g values n]: move the series by [n], negative to take away -- one
    [add g [] 1] as a thing opens and [add g [] (-1)] as it closes. *)

val sampled :
  t ->
  ?help:string ->
  ?unit:string ->
  ?labels:string list ->
  string ->
  (unit -> (string list * float) list) ->
  unit
(** [sampled t name read]: a gauge whose series are what [read] answers each
    time the metrics are read -- a pool's connections, a queue's length -- so
    what it measures needs no hook of its own. [read] runs on the fiber reading
    them, so it is quick and safe from any domain. Registered again under the
    same name and labels, a second [read] adds its series to the first's: two
    pools under one name, told apart by a label. A series [read] answers with a
    number of label values other than the family's is left out, and logged once:
    it is found while the metrics are read, where a raise would fail the whole
    page. *)

(** {1 Histograms} *)

type histogram

val histogram :
  t ->
  ?help:string ->
  ?unit:string ->
  ?labels:string list ->
  ?buckets:float list ->
  string ->
  histogram
(** How a value is distributed: a count per bucket, each bucket's bound the
    upper, and the sum. [buckets] are finite and increasing, OpenTelemetry's for
    a request's duration unless given -- [0.005] to [10] seconds. *)

val observe : histogram -> string list -> float -> unit

(** {1 Reading them} *)

val exposition : t -> string
(** Every metric in Prometheus's text format, version 0.0.4, in the order they
    were registered. *)

val routes : ?at:Path.path -> ?guard:unit Dep.t -> t -> Route.t list
(** [GET /metrics], or [at]: {!exposition}, its access line at [debug] as a
    probe's is, since something asks every few seconds. It is as public as a
    probe; an application that must not show it says who may with [guard], a
    dependency run first, whose refusal is the answer:

    {[
    Spindle.Metrics.routes ~guard:only_the_scraper metrics
    ]} *)

(** {1 What a server counts}

    With [~metrics], {!Server.run} counts, under OpenTelemetry's names:
    [http.server.request.duration], in seconds, by [http.request.method],
    [http.route] and [http.response.status_code] -- a request no route answered
    is counted under no route, and a method HTTP does not name under [_OTHER];
    [http.server.active_requests]; [spindle.server.open_connections]; and
    [spindle.server.body_budget.used], the bytes of request bodies held. *)
