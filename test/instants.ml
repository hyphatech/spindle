(* An instant written as milliseconds since 1970, as a test's rows give
   one, and read back: Ptime holds the years 0000 to 9999. *)

let day = 86_400_000

let of_ms ms =
  let d = (ms / day) - if ms mod day < 0 then 1 else 0 in
  match
    Option.bind
      (Ptime.Span.of_d_ps
         (d, Int64.mul (Int64.of_int (ms - (d * day))) 1_000_000_000L))
      Ptime.of_span
  with
  | Some t -> t
  | None -> Alcotest.failf "%d ms is no instant Ptime holds" ms

let to_ms t =
  let d, ps = Ptime.Span.to_d_ps (Ptime.to_span t) in
  (d * day) + Int64.to_int (Int64.div ps 1_000_000_000L)

let testable = Alcotest.testable (Ptime.pp_rfc3339 ~frac_s:3 ()) Ptime.equal
