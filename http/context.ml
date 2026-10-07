(* The request a fiber runs for: its id, its place in a trace, and the span
   it records, if any. On a fiber it is a binding, which forked fibers
   inherit; a systhread cannot read a fiber's bindings, so there it is kept in
   a table by thread for as long as the call that bound it. *)

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

(* Begun and not yet ended; written only by the fiber that began it. *)
type recording = {
  exporter : exporter;
  started_mono : int;
  mutable span : span;
}

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

let key : t Eio.Fiber.key = Eio.Fiber.create_key ()
let threads : (int, t) Hashtbl.t = Hashtbl.create 8
let threads_lock = Mutex.create ()
let thread_id () = Thread.id (Thread.self ())

(* The fiber first, which takes no lock; the table only where there is no
   fiber to ask: a systhread, or outside any Eio loop. *)
let current () =
  match Eio.Fiber.get key with
  | c -> c
  | exception Effect.Unhandled _ ->
      Mutex.protect threads_lock (fun () ->
          Hashtbl.find_opt threads (thread_id ()))

(* On a thread the table entry is restored when [f] returns. A test calling
   an app outside any Eio loop takes this path too. *)
let bind c f =
  match Eio.Fiber.get key with
  | _ -> Eio.Fiber.with_binding key c f
  | exception Effect.Unhandled _ ->
      let t = thread_id () in
      let before =
        Mutex.protect threads_lock (fun () ->
            let before = Hashtbl.find_opt threads t in
            Hashtbl.replace threads t c;
            before)
      in
      Fun.protect
        ~finally:(fun () ->
          Mutex.protect threads_lock (fun () ->
              match before with
              | Some b -> Hashtbl.replace threads t b
              | None -> Hashtbl.remove threads t))
        f

(* ------------------------------------------------------------------ *)
(* Ids *)

(* Per domain, so making an id takes no lock; seeded from the system, since
   [Random]'s default state repeats after every restart. *)
let random = Domain.DLS.new_key Random.State.make_self_init
let alphabet = "0123456789abcdefghjkmnpqrstvwxyz"

let fresh_id () =
  let r = Domain.DLS.get random in
  String.init 12 (fun _ -> alphabet.[Random.State.int r 32])

let is_all_zeros s = String.for_all (Char.equal '0') s

(* W3C Trace Context reserves all zeros as invalid. *)
let rec fresh_hex n =
  let r = Domain.DLS.get random in
  let s = String.init n (fun _ -> "0123456789abcdef".[Random.State.int r 16]) in
  if is_all_zeros s then fresh_hex n else s

(* Whether a new trace is recorded, at the exporter's ratio. *)
let sample_root e =
  e.ratio >= 1.
  || (e.ratio > 0. && Random.State.float (Domain.DLS.get random) 1. < e.ratio)

(* ------------------------------------------------------------------ *)
(* Spans *)

let start_span exporter ~trace_id ~span_id ~parent_id ~kind ~attributes name =
  {
    exporter;
    started_mono = exporter.mono_ns ();
    span =
      {
        trace_id;
        span_id;
        parent_id;
        name;
        kind;
        start_ns = exporter.wall_ns ();
        end_ns = 0;
        attributes;
        status = Unset;
      };
  }

(* Start time from the wall clock, length from the monotonic one, so a wall
   clock jumping mid-span cannot change the length. *)
let end_span (u : recording) =
  let length = u.exporter.mono_ns () - u.started_mono in
  u.exporter.record { u.span with end_ns = u.span.start_ns + max 0 length }

let add_attributes (u : recording) attributes =
  u.span <- { u.span with attributes = u.span.attributes @ attributes }

(* The constructor only: the message may carry the data being handled. *)
let record_raise (u : recording) ex =
  let kind = Printexc.exn_slot_name ex in
  add_attributes u [ ("exception.type", `String kind) ];
  u.span <- { u.span with status = Error kind }

(* Ends [u] when [f] returns or raises. *)
let with_span u f =
  match f () with
  | v ->
      end_span u;
      v
  | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      record_raise u ex;
      end_span u;
      Printexc.raise_with_backtrace ex bt
