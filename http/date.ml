(* Each form has a fixed shape, so each is read by position. *)

let ( let* ) = Option.bind

let read_digits s ~at n =
  let rec go i acc =
    if i = n then Some acc
    else
      match s.[at + i] with
      | '0' .. '9' as c -> go (i + 1) ((acc * 10) + Char.code c - 48)
      | _ -> None
  in
  if at >= 0 && at + n <= String.length s then go 0 0 else None

let has_text_at s ~at text =
  at + String.length text <= String.length s
  && String.equal (String.sub s at (String.length text)) text

(* Case-sensitive, as every part of an HTTP-date is. *)
let index_of_name names s ~at =
  let rec go i =
    if i = Array.length names then None
    else if has_text_at s ~at names.(i) then Some i
    else go (i + 1)
  in
  go 0

let long_days =
  [|
    "Monday"; "Tuesday"; "Wednesday"; "Thursday"; "Friday"; "Saturday"; "Sunday";
  |]

let read_month s ~at = Option.map succ (index_of_name Calendar.months s ~at)

(* [HH:MM:SS], a second of 60 being a leap second. *)
let read_time s ~at =
  let* h = read_digits s ~at 2 in
  let* m = read_digits s ~at:(at + 3) 2 in
  let* sec = read_digits s ~at:(at + 6) 2 in
  if
    has_text_at s ~at:(at + 2) ":"
    && has_text_at s ~at:(at + 5) ":"
    && h <= 23 && m <= 59 && sec <= 60
  then Some ((h * 3600) + (m * 60) + sec)
  else None

let instant_ms ~year ~month ~day secs =
  if day < 1 || day > Calendar.days_in ~year ~month then None
  else Some (((Calendar.days_of_civil ~year ~month ~day * 86_400) + secs) * 1000)

(* [Sun, 06 Nov 1994 08:49:37 GMT] *)
let parse_imf_fixdate s =
  let* _ = index_of_name Calendar.weekdays s ~at:0 in
  let* day = read_digits s ~at:5 2 in
  let* month = read_month s ~at:8 in
  let* year = read_digits s ~at:12 4 in
  let* secs = read_time s ~at:17 in
  if
    has_text_at s ~at:3 ", " && has_text_at s ~at:7 " "
    && has_text_at s ~at:11 " " && has_text_at s ~at:16 " "
    && has_text_at s ~at:25 " GMT"
  then instant_ms ~year ~month ~day secs
  else None

(* [Sun Nov  6 08:49:37 1994], the day a digit after a space when it is one. *)
let parse_asctime s =
  let* _ = index_of_name Calendar.weekdays s ~at:0 in
  let* month = read_month s ~at:4 in
  let* day =
    if has_text_at s ~at:8 " " then read_digits s ~at:9 1
    else read_digits s ~at:8 2
  in
  let* secs = read_time s ~at:11 in
  let* year = read_digits s ~at:20 4 in
  if
    has_text_at s ~at:3 " " && has_text_at s ~at:7 " "
    && has_text_at s ~at:10 " " && has_text_at s ~at:19 " "
  then instant_ms ~year ~month ~day secs
  else None

(* [Sunday, 06-Nov-94 08:49:37 GMT]: a date more than fifty years ahead of
   now is the century before (RFC 9110 §5.6.7). *)
let parse_rfc850 ~now s =
  let* comma = String.index_opt s ',' in
  let* () =
    if Array.exists (String.equal (String.sub s 0 comma)) long_days then Some ()
    else None
  in
  let at = comma + 2 in
  let* day = read_digits s ~at 2 in
  let* month = read_month s ~at:(at + 3) in
  let* yy = read_digits s ~at:(at + 7) 2 in
  let* secs = read_time s ~at:(at + 10) in
  let now_s = Calendar.floor_div now 1000 in
  let today = Calendar.floor_div now_s 86_400 in
  let this_year, this_month, this_day = Calendar.civil_of_days today in
  let year = this_year - (this_year mod 100) + yy in
  (* The first field that differs from fifty years on decides, so that day
     needs no 29 February its year may not have. *)
  let is_past_fifty_years =
    match
      List.find_opt
        (fun c -> c <> 0)
        [
          Int.compare year (this_year + 50);
          Int.compare month this_month;
          Int.compare day this_day;
          Int.compare secs (now_s - (today * 86_400));
        ]
    with
    | Some c -> c > 0
    | None -> false
  in
  let year = if is_past_fifty_years then year - 100 else year in
  if
    String.length s = at + 22
    && has_text_at s ~at:comma ", "
    && has_text_at s ~at:(at + 2) "-"
    && has_text_at s ~at:(at + 6) "-"
    && has_text_at s ~at:(at + 9) " "
    && has_text_at s ~at:(at + 18) " GMT"
  then instant_ms ~year ~month ~day secs
  else None

let parse ~now s =
  match String.length s with
  | 29 -> parse_imf_fixdate s
  | 24 -> parse_asctime s
  | _ -> parse_rfc850 ~now s
