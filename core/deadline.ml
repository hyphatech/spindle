(* A deadline per connection and a sweep per domain, so moving a deadline is
   a field write rather than a timer. A sweep and its connections share a
   domain, so fields are mutated without a lock, and the sweep cancels only
   contexts on its own domain, which is all Eio allows. *)

(* Our own, so another cancellation, the server stopping, is never taken for
   a passed deadline. *)
exception Passed

(* Instants and spans are nanoseconds in an [int], so moving a deadline --
   once a flush, once a read -- is a write of an immediate, never a fresh
   [Mtime.t] boxed into a record that outlives every minor collection. Past
   what an [int] counts to is never: [max_int]. *)
let never = max_int
let ns span = Int64.to_int (Mtime.Span.to_uint64_ns span)
let now clock = Int64.to_int (Mtime.to_uint64_ns (Eio.Time.Mono.now clock))
let later ~by at = if at > never - by then never else at + by

type t = {
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  mutable due_at : int;  (** [never] when armed for nothing *)
  mutable pace_ns : int;
      (** A body keeps up a rate, each byte buying [pace_ns]; a write keeps
          going, each byte restarting the allowance, [pace_ns] from it. *)
  mutable since_last : bool;
  mutable waiting : Eio.Cancel.t option;
  mutable passed : bool;
}

type sweep = {
  sweep_clock : Eio.Time.Mono.ty Eio.Resource.t;
  tick : Mtime.Span.t;
  deadlines : (int, t) Hashtbl.t;
  mutable next_id : int;
}

(* Arming starts afresh: the answer to a passed deadline, a 408 say, is a
   wait of its own. *)
let arm_with t ~since_last ~pace span =
  t.due_at <- later ~by:(ns span) (now t.clock);
  t.pace_ns <- pace;
  t.since_last <- since_last;
  t.passed <- false

let arm ?(per_byte = Mtime.Span.zero) t span =
  arm_with t ~since_last:false ~pace:(ns per_byte) span

let arm_since_last t span = arm_with t ~since_last:true ~pace:(ns span) span
let clear t = t.due_at <- never

let remaining t =
  if t.due_at = never then None
  else
    let left = t.due_at - now t.clock in
    Some (Mtime.Span.of_uint64_ns (Int64.of_int (max 0 left)))

let passed t = t.passed

let progress t n =
  if t.due_at <> never && n > 0 then
    if t.since_last then t.due_at <- later ~by:t.pace_ns (now t.clock)
    else
      t.due_at <-
        (if t.pace_ns > 0 && n > (never - t.due_at) / t.pace_ns then never
         else t.due_at + (n * t.pace_ns))

(* Each wait in a cancellation context of its own, so the sweep interrupts
   the wait and nothing else. *)
let wait t f =
  if t.passed then None
  else
    match
      Eio.Cancel.sub (fun cc ->
          t.waiting <- Some cc;
          Fun.protect ~finally:(fun () -> t.waiting <- None) f)
    with
    | v -> Some v
    | exception Eio.Cancel.Cancelled Passed -> None

let sweep ~mono_clock:clock ~tick =
  {
    sweep_clock = (clock :> Eio.Time.Mono.ty Eio.Resource.t);
    tick;
    deadlines = Hashtbl.create 64;
    next_id = 0;
  }

(* Cancelling only schedules the waiting fiber, so nothing leaves the table
   during the walk. *)
let rec watch s =
  Eio.Time.Mono.sleep_span s.sweep_clock s.tick;
  let now = now s.sweep_clock in
  Hashtbl.iter
    (fun _ t ->
      if t.due_at <> never && t.due_at <= now then (
        t.passed <- true;
        t.due_at <- never;
        Option.iter (fun cc -> Eio.Cancel.cancel cc Passed) t.waiting))
    s.deadlines;
  watch s

let run s f =
  let t =
    {
      clock = s.sweep_clock;
      due_at = never;
      pace_ns = 0;
      since_last = false;
      waiting = None;
      passed = false;
    }
  in
  let id = s.next_id in
  s.next_id <- id + 1;
  Hashtbl.replace s.deadlines id t;
  Fun.protect ~finally:(fun () -> Hashtbl.remove s.deadlines id) (fun () -> f t)

module Reading = struct
  type nonrec t = { deadline : t; flow : Eio.Flow.source_ty Eio.Resource.t }

  let read_methods = []

  let single_read { deadline = d; flow } buf =
    match wait d (fun () -> Eio.Flow.single_read flow buf) with
    | Some n ->
        progress d n;
        n
    | None -> raise End_of_file
end

let reading deadline flow =
  Eio.Resource.T
    ( { Reading.deadline; flow :> Eio.Flow.source_ty Eio.Resource.t },
      Eio.Flow.Pi.source (module Reading) )
