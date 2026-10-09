(** The library's one log source, [spindle_postgres]: a pool that could not be
    opened, and one with no connection free within its wait. *)

val src : Logs.src
