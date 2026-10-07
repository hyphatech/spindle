(** Spans: what a request did, and how long each part of it took, recorded under
    the W3C trace {!Log} already carries, so a server, the calls it makes and
    the statements it runs are one trace.

    Nothing is recorded unless an {!type-exporter} is given where the request
    begins, and the trace is kept: a trace begun here at the exporter's ratio,
    one joined from a caller as the caller's [traceparent] says. Everything else
    is one lookup that finds nothing to record.

    {b A secret has no span.} No header value, body, query string or statement
    parameter is ever an attribute, as none is ever a log field. *)

type value =
  [ `String of string | `Int of int | `Float of float | `Bool of bool ]
(** An attribute's value, as a log field's is ({!Log.value}). *)

(** Which side of an exchange a span is: a request this server answered, a call
    it made -- to another server, or a statement to its database -- or work of
    its own. *)
type kind = Server | Client | Internal

(** Whether it went wrong: [Unset] unless it did, and [Error] naming how -- a
    raise's constructor, or a server's [5xx]. *)
type status = Unset | Error of string

type span = {
  trace_id : string;  (** thirty-two lowercase hex digits *)
  span_id : string;  (** sixteen *)
  parent_id : string option;  (** [None] for a trace's root *)
  name : string;
  kind : kind;
  start_ns : int;  (** since the epoch, by the wall clock *)
  end_ns : int;
      (** its start and its length on the monotonic clock, so a wall clock that
          jumps moves a span and never lengthens one *)
  attributes : (string * value) list;
  status : status;
}
(** A span as it is recorded, once it has ended. *)

type exporter = Context.exporter
(** Where spans go, and how many traces are kept. *)

val exporter :
  ?ratio:float ->
  clock:_ Eio.Time.clock ->
  mono_clock:_ Eio.Time.Mono.t ->
  (span -> unit) ->
  exporter
(** [exporter ~clock ~mono_clock record]: [record] is handed every span of a
    kept trace as it ends, on whichever fiber and domain ended it, so it is
    quick and synchronised -- a queue another fiber sends from, as
    [Spindle_client.Otlp] keeps. [ratio] (1.0) is the share of the traces begun
    here that are kept; a trace joined from a caller is kept exactly when the
    caller's is, so a trace is whole or absent. *)

val span :
  ?kind:kind ->
  ?attributes:(string * value) list ->
  string ->
  (unit -> 'a) ->
  'a
(** [span name f] runs [f] as a span of its own, a child of the one the fiber is
    in -- the request's, or another [span] around it -- and records it when [f]
    returns or raises; a raise is its status, by constructor, and passes. A call
    made inside it, and a statement run, are its children.

    {[
    Spindle.Trace.span "price the order" (fun () -> price order)
    ]}

    [kind] is [Internal] unless given. Outside a kept trace it is [f ()]. *)

(** {1 A span whose name is known only at its end}

    What a server and a client record theirs with: the request's span is named
    once a route has answered it. *)

type recording
(** A span begun and not yet ended -- or, outside a kept trace, nothing, which
    everything below does nothing to. *)

val within :
  ?kind:kind ->
  ?attributes:(string * value) list ->
  string ->
  (recording -> 'a) ->
  'a
(** {!val-span}, handing [f] the span it records. *)

val current : unit -> recording
(** The span the fiber is in: inside a request, that request's own until a
    {!val-span} is begun inside it. *)

val rename : recording -> string -> unit

val add : recording -> (string * value) list -> unit
(** Attributes, after the ones it has. *)

val fail : recording -> string -> unit
(** Its status [Error], saying how. *)
