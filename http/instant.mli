(** Instants, as a [Ptime.t], and the waits between them, as an [Mtime.Span.t]:
    what a clock is read into, and the one place a wait until an instant is
    worked out. *)

val of_clock : _ Eio.Time.clock -> Ptime.t
(** The clock's time now. A clock reads a time within the years 0000 to 9999,
    and one that does not is read as the nearest instant in them. *)

val until : now:Ptime.t -> Ptime.t -> Mtime.Span.t
(** [until ~now deadline] is how long from [now] until [deadline], rounded up to
    the nanosecond, and zero once it has passed, since a wait cannot be
    negative:

    {[
    Eio.Time.Mono.sleep_span clock (Instant.until ~now session_ends)
    ]} *)

val add : Ptime.t -> Mtime.Span.t -> Ptime.t
(** [add t span] is [span] after [t], or the latest instant of 9999 when that is
    later. *)
