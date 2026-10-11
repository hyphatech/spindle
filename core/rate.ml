(* Every instant is the monotonic clock's. *)

type t = {
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
  interval : Mtime.Span.t;  (** between two calls, at the sustained rate *)
  tolerance : Mtime.Span.t;  (** how far ahead of now a key's instant may run *)
  next_allowed : (string, Mtime.t) Hashtbl.t;
      (** GCRA's theoretical arrival time per key: the soonest it may call *)
  lock : Eio.Mutex.t;
  mutable writes_since_sweep : int;
}

let create ~mono_clock ~limit ~per ?(burst = limit) () =
  let refuse what = invalid_arg ("Spindle.Rate.create: " ^ what) in
  if limit < 1 then refuse (Printf.sprintf "~limit:%d, below one" limit);
  if burst < 1 then refuse (Printf.sprintf "~burst:%d, below one" burst);
  if Mtime.Span.equal per Mtime.Span.zero then refuse "~per, a span of zero";
  let interval =
    Mtime.Span.of_uint64_ns
      (Int64.unsigned_div (Mtime.Span.to_uint64_ns per) (Int64.of_int limit))
  in
  {
    mono_clock :> Eio.Time.Mono.ty Eio.Resource.t;
    interval;
    tolerance = Mtime.Span.((burst - 1) * interval);
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
      (fun k at acc -> if Mtime.is_later at ~than:now then acc else k :: acc)
      t.next_allowed []
  in
  List.iter (Hashtbl.remove t.next_allowed) passed

(* GCRA: a call passes while the key's instant is within the burst of now,
   and moves it on one interval. *)
let check t key =
  let now = Eio.Time.Mono.now t.mono_clock in
  Eio.Mutex.use_rw ~protect:false t.lock (fun () ->
      let at =
        match Hashtbl.find_opt t.next_allowed key with
        | Some at when Mtime.is_later at ~than:now -> at
        | Some _ | None -> now
      in
      let ahead = Mtime.span now at in
      if Mtime.Span.is_longer ahead ~than:t.tolerance then
        `Wait (Mtime.Span.abs_diff ahead t.tolerance)
      else (
        Hashtbl.replace t.next_allowed key
          (Option.value (Mtime.add_span at t.interval) ~default:Mtime.max_stamp);
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
         | `Wait span ->
             (* Whole seconds, rounded up, as [Retry-After] counts them. *)
             let ns = Mtime.Span.to_uint64_ns span in
             Error
               (Refusal.rate_limited
                  ~retry_after_s:
                    (Int64.to_int
                       (Int64.unsigned_div
                          (Int64.add ns 999_999_999L)
                          1_000_000_000L))))
       key)
