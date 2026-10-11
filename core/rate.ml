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
  let refuse what = invalid_arg ("Spindle.Rate.create: " ^ what) in
  if limit < 1 then refuse (Printf.sprintf "~limit:%d, below one" limit);
  if burst < 1 then refuse (Printf.sprintf "~burst:%d, below one" burst);
  if not (Float.is_finite per_s && per_s > 0.) then
    refuse (Printf.sprintf "~per_s:%g, not a positive number of seconds" per_s);
  let interval = int_of_float (per_s *. 1e9 /. float_of_int limit) in
  {
    now =
      (fun () ->
        Int64.to_int (Mtime.to_uint64_ns (Eio.Time.Mono.now mono_clock)));
    interval;
    tolerance = interval * (burst - 1);
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

(* An IPv6 host makes its own address within its link's /64 (RFC 4862), and
   may make a new one as often as it likes (RFC 8981), so the /64 is who is
   counted. An IPv4 address mapped into IPv6 is that IPv4 address. *)
let counted key =
  match Ipaddr.of_string key with
  | Ok (Ipaddr.V6 a) -> (
      match Ipaddr.v4_of_v6 a with
      | Some v4 -> Ipaddr.V4.to_string v4
      | None ->
          Ipaddr.V6.Prefix.to_string
            (Ipaddr.V6.Prefix.prefix (Ipaddr.V6.Prefix.make 64 a)))
  | Ok (Ipaddr.V4 a) -> Ipaddr.V4.to_string a
  | Error _ -> key

let limit t ~key =
  Dep.join
    ~refuses:[ Refusal.Code.rate_limited ]
    (Dep.map
       (fun k ->
         match check t (counted k) with
         | `Pass -> Ok ()
         | `Wait ns ->
             Error
               (Refusal.rate_limited
                  ~retry_after_s:((ns + 999_999_999) / 1_000_000_000)))
       key)
