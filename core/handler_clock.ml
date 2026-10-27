(* A handler's time, its body's reads left out, and the limit on it. *)

module L = (val Logs.src_log Log.http : Logs.LOG)

type t = {
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  mutable started : Mtime.t;
  mutable read : Mtime.Span.t;  (** spent in reads that have ended *)
  mutable reading_since : Mtime.t option;
  read_ended : Eio.Condition.t;
}

let create clock =
  let clock = (clock :> Eio.Time.Mono.ty Eio.Resource.t) in
  {
    clock;
    started = Eio.Time.Mono.now clock;
    read = Mtime.Span.zero;
    reading_since = None;
    read_ended = Eio.Condition.create ();
  }

let reading t read =
  let since = Eio.Time.Mono.now t.clock in
  t.reading_since <- Some since;
  Fun.protect
    ~finally:(fun () ->
      t.read <-
        Mtime.Span.add t.read (Mtime.span since (Eio.Time.Mono.now t.clock));
      t.reading_since <- None;
      Eio.Condition.broadcast t.read_ended)
    read

(* The reads are inside the time since it started, so taking them away
   never goes below zero. *)
let spent t =
  let ns span = Mtime.Span.to_uint64_ns span in
  Mtime.Span.of_uint64_ns
    (Int64.sub
       (ns (Mtime.span t.started (Eio.Time.Mono.now t.clock)))
       (ns t.read))

(* The watch sleeps only for what is left, and waits out a read in progress,
   whose time is not the handler's; a connection's fibers share a domain, so
   nothing runs between the check and the wait. *)
let within t ~limit handler =
  t.started <- Eio.Time.Mono.now t.clock;
  t.read <- Mtime.Span.zero;
  let rec watch () =
    match t.reading_since with
    | Some _ ->
        Eio.Condition.await_no_mutex t.read_ended;
        watch ()
    | None ->
        let spent = spent t in
        if Mtime.Span.compare spent limit < 0 then (
          Eio.Time.Mono.sleep_span t.clock (Mtime.Span.abs_diff limit spent);
          watch ())
  in
  Eio.Fiber.first
    (fun () -> Ok (handler ()))
    (fun () ->
      watch ();
      Error ())

let refusal ~route ~limit =
  L.warn (fun m ->
      m "%s ran past its handler_timeout of %a, and was cancelled" route
        Mtime.Span.pp limit);
  Response.refusal Refusal.timed_out
