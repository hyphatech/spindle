(** The proleptic Gregorian calendar, in days counted from 1970-01-01: what an
    HTTP-date is written from and read into. *)

val floor_div : int -> int -> int
(** Division that rounds down, so an instant before the epoch lands on the day
    it is in. *)

val civil_of_days : int -> int * int * int
(** The year, month and day of a day. *)

val days_of_civil : year:int -> month:int -> day:int -> int

val days_in : year:int -> month:int -> int
(** How many days the month has that year. *)

val weekdays : string array
(** Three-letter names, from 1970-01-01's, a Thursday. *)

val months : string array
(** Three-letter names, January first. *)
