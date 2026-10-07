(* Every instant is nanoseconds on the monotonic clock. *)

type t = {
  now : unit -> int;
  interval : int;  (** between two calls, at the sustained rate *)
  tolerance : int;  (** how far ahead of now a key's instant may run *)
  next_allowed : (string, int) Hashtbl.t;
      (** GCRA's theoretical arrival time per key: the soonest it may call *)
  lock : Eio.Mutex.t;
  mutable writes_since_sweep : int;
}

let create ~mono_clock ~limit ~per_s ?(burst = limit) () =
  let interval = int_of_float (per_s *. 1e9 /. float_of_int (max 1 limit)) in
  {
    now =
      (fun () ->
        Int64.to_int (Mtime.to_uint64_ns (Eio.Time.Mono.now mono_clock)));
    interval;
    tolerance = interval * (max 1 burst - 1);
    next_allowed = Hashtbl.create 64;
    lock = Eio.Mutex.create ();
    writes_since_sweep = 0;
  }

(* A sweep walks the whole table, so it is made once in many writes. *)
let writes_per_sweep = 1000

(* A key whose instant has passed is as good as never seen. *)
let sweep t now =
  let passed =
    Hashtbl.fold
      (fun k at acc -> if at <= now then k :: acc else acc)
      t.next_allowed []
  in
  List.iter (Hashtbl.remove t.next_allowed) passed

(* GCRA: a call passes while the key's instant is within the burst of now,
   and moves it on one interval. *)
let check t key =
  let now = t.now () in
  Eio.Mutex.use_rw ~protect:false t.lock (fun () ->
      let at =
        max now
          (Option.value (Hashtbl.find_opt t.next_allowed key) ~default:now)
      in
      if at - now > t.tolerance then `Wait (at - now - t.tolerance)
      else (
        Hashtbl.replace t.next_allowed key (at + t.interval);
        t.writes_since_sweep <- t.writes_since_sweep + 1;
        if t.writes_since_sweep mod writes_per_sweep = 0 then sweep t now;
        `Pass))

let limit t ~key =
  Dep.join
    ~refuses:[ Refusal.Code.rate_limited ]
    (Dep.map
       (fun k ->
         match check t k with
         | `Pass -> Ok ()
         | `Wait ns ->
             Error
               (Refusal.rate_limited
                  ~retry_after:((ns + 999_999_999) / 1_000_000_000)
                  ()))
       key)
