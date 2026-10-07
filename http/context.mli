(** The request a fiber runs for: its id, its place in a trace, and the span it
    records, if any -- what {!Log} and {!Trace} are both built on. *)

type value =
  [ `String of string | `Int of int | `Float of float | `Bool of bool ]

type kind = Server | Client | Internal
type status = Unset | Error of string

type span = {
  trace_id : string;
  span_id : string;
  parent_id : string option;
  name : string;
  kind : kind;
  start_ns : int;
  end_ns : int;
  attributes : (string * value) list;
  status : status;
}

type exporter = {
  record : span -> unit;
  ratio : float;
  wall_ns : unit -> int;
  mono_ns : unit -> int;
}

type recording = {
  exporter : exporter;
  started_mono : int;
  mutable span : span;
}
(** A span begun and not yet ended, written only by the fiber that began it. *)

type t = {
  id : string;
  trace_id : string;
  span_id : string;
  sampled : bool;
      (** the caller's sampled flag, or this server's where it began the trace
      *)
  tracestate : string option;  (** the caller's, passed on as it came *)
  span : recording option;  (** the span recorded, whose id is [span_id] *)
}

val current : unit -> t option
(** The fiber's, or on a systhread or outside any Eio loop, the thread's. *)

val bind : t -> (unit -> 'a) -> 'a
(** [f] run as [c]'s, and the fibers it forks with it. *)

val fresh_id : unit -> string
(** A request's id: twelve characters, from a generator per domain. *)

val is_all_zeros : string -> bool
(** Whether a trace or span id is all zeros, which W3C Trace Context reserves as
    invalid. *)

val fresh_hex : int -> string
(** [n] hexadecimal digits, never all zeros. *)

val sample_root : exporter -> bool
(** Whether a trace begun here is recorded, at the exporter's ratio. *)

val start_span :
  exporter ->
  trace_id:string ->
  span_id:string ->
  parent_id:string option ->
  kind:kind ->
  attributes:(string * value) list ->
  string ->
  recording

val add_attributes : recording -> (string * value) list -> unit

val with_span : recording -> (unit -> 'a) -> 'a
(** [f ()], the span ended when it returns or raises; a raise is recorded as its
    constructor and goes on. *)
