(* A Ptime span is days and picoseconds; an Mtime span unsigned nanoseconds,
   which run out at about 584 years. *)
let ns_per_day = 86_400_000_000_000L
let ps_per_ns = 1_000L

(* The library's clock module: the two calls with no typed form, a clock's
   float of seconds and [Unix.sleepf]'s, are made here and nowhere else. *)
let of_clock clock =
  let s = Eio.Time.now clock in
  match Ptime.of_float_s s with
  | Some t -> t
  | None -> if Float.compare s 0. < 0 then Ptime.min else Ptime.max

(* Rounded up to the nanosecond, so a wait never ends before its deadline. *)
let until ~now deadline =
  if not (Ptime.is_later deadline ~than:now) then Mtime.Span.zero
  else
    let d, ps = Ptime.Span.to_d_ps (Ptime.diff deadline now) in
    let ns_into_day =
      Int64.add (Int64.div ps ps_per_ns)
        (if Int64.equal (Int64.rem ps ps_per_ns) 0L then 0L else 1L)
    in
    if Int64.compare (Int64.of_int d) (Int64.unsigned_div (-1L) ns_per_day) >= 0
    then Mtime.Span.max_span
    else
      Mtime.Span.of_uint64_ns
        (Int64.add (Int64.mul (Int64.of_int d) ns_per_day) ns_into_day)

let add t span =
  let ns = Mtime.Span.to_uint64_ns span in
  let d = Int64.to_int (Int64.unsigned_div ns ns_per_day) in
  let ps = Int64.mul (Int64.unsigned_rem ns ns_per_day) ps_per_ns in
  match Option.bind (Ptime.Span.of_d_ps (d, ps)) (Ptime.add_span t) with
  | Some later -> later
  | None -> Ptime.max

let sleep span = Unix.sleepf (Mtime.Span.to_float_ns span /. 1e9)
