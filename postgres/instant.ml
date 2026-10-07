(* Spindle's instants are epoch milliseconds and rowtype's a [Ptime.t]:
   converted exactly, through days and picoseconds. One Ptime cannot hold,
   outside its years 0 to 9999, is written as the nearest it can -- year 0
   then being the column's to refuse -- and below the millisecond is dropped
   on reading. *)

let ms_per_day = 86_400_000
let ps_per_ms = 1_000_000_000L

let ms =
  Rowtype.conv Rowtype.instant
    ~of_:(fun t ->
      let d, ps = Ptime.Span.to_d_ps (Ptime.to_span t) in
      (d * ms_per_day) + Int64.to_int (Int64.div ps ps_per_ms))
    ~to_:(fun ms ->
      let d = (ms / ms_per_day) - if ms mod ms_per_day < 0 then 1 else 0 in
      let into_day =
        Int64.mul (Int64.of_int (ms - (d * ms_per_day))) ps_per_ms
      in
      Option.bind (Ptime.Span.of_d_ps (d, into_day)) Ptime.of_span
      |> Option.value ~default:(if ms < 0 then Ptime.min else Ptime.max))
