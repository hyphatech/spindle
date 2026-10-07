(* A deadline per connection and a sweep per domain, so moving a deadline is
   a field write rather than a timer. A sweep and its connections share a
   domain, so fields are mutated without a lock, and the sweep cancels only
   contexts on its own domain, which is all Eio allows. *)

(* Our own, so another cancellation, the server stopping, is never taken for
   a passed deadline. *)
exception Passed

(* A body keeps up a rate, each byte buying time; a write keeps going, each
   byte restarting the allowance. *)
type pace = Per_byte of float | Since_last of float

type t = {
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  mutable due_at : Mtime.t option;
  mutable pace : pace;
  mutable waiting : Eio.Cancel.t option;
  mutable passed : bool;
}

type sweep = {
  sweep_clock : Eio.Time.Mono.ty Eio.Resource.t;
  tick : float;
  deadlines : (int, t) Hashtbl.t;
  mutable next_id : int;
}

(* Past what the clock counts to is never. *)
let add_seconds ~by at =
  let ns = Mtime.Span.of_uint64_ns (Int64.of_float (Float.max 0. by *. 1e9)) in
  Option.value (Mtime.add_span at ns) ~default:Mtime.max_stamp

(* Arming starts afresh: the answer to a passed deadline, a 408 say, is a
   wait of its own. *)
let arm_with t pace s =
  t.due_at <- Some (add_seconds ~by:s (Eio.Time.Mono.now t.clock));
  t.pace <- pace;
  t.passed <- false

let arm ?(per_byte = 0.) t s = arm_with t (Per_byte per_byte) s
let arm_since_last t s = arm_with t (Since_last s) s
let clear t = t.due_at <- None

let remaining t =
  Option.map
    (fun at ->
      let now = Eio.Time.Mono.now t.clock in
      if Mtime.is_later at ~than:now then
        Mtime.Span.to_float_ns (Mtime.span now at) /. 1e9
      else -.(Mtime.Span.to_float_ns (Mtime.span now at) /. 1e9))
    t.due_at

let passed t = t.passed

let progress t n =
  match (t.due_at, t.pace) with
  | None, _ -> ()
  | Some at, Per_byte p ->
      t.due_at <- Some (add_seconds ~by:(float_of_int n *. p) at)
  | Some _, Since_last s ->
      if n > 0 then
        t.due_at <- Some (add_seconds ~by:s (Eio.Time.Mono.now t.clock))

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
  Eio.Time.Mono.sleep s.sweep_clock s.tick;
  let now = Eio.Time.Mono.now s.sweep_clock in
  Hashtbl.iter
    (fun _ t ->
      match t.due_at with
      | Some at when not (Mtime.is_later at ~than:now) ->
          t.passed <- true;
          t.due_at <- None;
          Option.iter (fun cc -> Eio.Cancel.cancel cc Passed) t.waiting
      | Some _ | None -> ())
    s.deadlines;
  watch s

let run s f =
  let t =
    {
      clock = s.sweep_clock;
      due_at = None;
      pace = Per_byte 0.;
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
