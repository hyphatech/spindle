(** What a line is made of, on either end of a call: the framework's source, a
    line's structured fields, and the request a fiber runs for.

    The reporter that writes a line is [Spindle.Log]'s; this is what a server
    and a client both write lines with, so that a call made while a request is
    answered logs under that request. *)

val http : Logs.src
(** [spindle.http]: the framework's own lines -- the access log, a refusal's
    detail, a connection that failed. *)

type value =
  [ `String of string | `Int of int | `Float of float | `Bool of bool ]

val pp_value : Format.formatter -> value -> unit

val fields : (string * value) list Logs.Tag.def
(** Structured fields on a line. A shipper filters on a field; it cannot filter
    on something interpolated into the message. *)

val tags : (string * value) list -> Logs.Tag.set
(** [~tags:(Spindle.Log.tags [ ("status", `Int 202) ])] *)

val raised : exn -> Printexc.raw_backtrace -> (string * value) list
(** A caught exception as fields: [error.kind], its constructor;
    [error.message]; and [error.stack], left out when nothing was recorded --
    the names an error tracker groups a failure by. Take the backtrace first
    thing in the handler, [Printexc.get_raw_backtrace ()], since the next raise
    on the domain replaces it. *)

(** {1 The request a fiber runs for}

    Its id, and where it stands in a W3C trace: a trace id every server the
    request reaches shares, and a span id of this server's own. Every line
    logged for it carries all three, and a call made for it carries the trace
    onward in [traceparent]. *)

val request_id : unit -> string option
(** The id of the request this code is running for, if any. *)

val trace_id : unit -> string option
(** Its trace's id: thirty-two lowercase hex digits. *)

val span_id : unit -> string option
(** Its span's id on this server: sixteen lowercase hex digits. *)

val with_request_id :
  ?traceparent:string ->
  ?tracestate:string ->
  ?trace:Trace.exporter ->
  string ->
  (unit -> 'a) ->
  'a
(** Runs [f] as part of that request: every line it and the fibers it forks log
    carries the id. [traceparent] is the value of the header a caller sent: the
    request joins that trace as a span of its own. Without one, or with one that
    is not a W3C [traceparent], it begins a trace. [tracestate] is the caller's
    too, passed on to every call as it came, where it came with a trace and is
    no longer than the 512 characters W3C Trace Context asks be passed on.

    With [trace], the request's span is recorded, a {!Trace.Server} span named
    [request] until {!Trace.rename} names it, when the trace is kept
    ({!Trace.val-exporter}). *)

val traceparent : unit -> string option
(** The [traceparent] a call made for the current request sends: its trace, and
    the span the call is -- recorded, inside a {!Trace.val-span} of the call's
    own, or a fresh id nothing records. [None] outside a request. *)

val tracestate : unit -> string option
(** The [tracestate] a call sends beside it: the caller's, where it sent one. *)

val carry : (unit -> 'a) -> unit -> 'a
(** [carry f] is [f], taking the current request's id, trace and span with it to
    whichever fiber or thread runs it -- a fiber on another domain, or a call
    handed to a systhread, where a fiber's bindings cannot be read. Capture
    where the request is, run where the work is. *)

val fresh_id : unit -> string
(** Twelve characters, unique enough to find one request among a day's. *)
