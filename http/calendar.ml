(* The proleptic Gregorian calendar, in days counted from 1970-01-01: what
   an HTTP-date is written from and read into. *)

(* Division that rounds down, so an instant before the epoch still lands on
   the day it is in. *)
let floor_div a b = if a >= 0 then a / b else ((a + 1) / b) - 1

(* Howard Hinnant's days-to-civil: whole 400-year eras, then the year, day
   and month within one that starts in March, so the leap day falls last. *)
let civil_of_days days =
  let z = days + 719_468 in
  let era = floor_div z 146_097 in
  let doe = z - (era * 146_097) in
  let yoe = (doe - (doe / 1460) + (doe / 36_524) - (doe / 146_096)) / 365 in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let day = doy - (((153 * mp) + 2) / 5) + 1 in
  let month = if mp < 10 then mp + 3 else mp - 9 in
  let year = yoe + (era * 400) + if month <= 2 then 1 else 0 in
  (year, month, day)

(* Hinnant's days-from-civil. *)
let days_of_civil ~year ~month ~day =
  let year = if month <= 2 then year - 1 else year in
  let era = floor_div year 400 in
  let yoe = year - (era * 400) in
  let doy = (((153 * ((month + 9) mod 12)) + 2) / 5) + day - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146_097) + doe - 719_468

let is_leap_year year =
  (year mod 4 = 0 && year mod 100 <> 0) || year mod 400 = 0

let days_in ~year ~month =
  match month with
  | 2 -> if is_leap_year year then 29 else 28
  | 4 | 6 | 9 | 11 -> 30
  | _ -> 31

(* 1970-01-01 was a Thursday. *)
let weekdays = [| "Thu"; "Fri"; "Sat"; "Sun"; "Mon"; "Tue"; "Wed" |]

let months =
  [|
    "Jan";
    "Feb";
    "Mar";
    "Apr";
    "May";
    "Jun";
    "Jul";
    "Aug";
    "Sep";
    "Oct";
    "Nov";
    "Dec";
  |]
