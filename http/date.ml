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

(* [HH:MM:SS], a second of 60 being a leap second, which Ptime reads as the
   next minute's first. *)
let read_time s ~at =
  let* h = read_digits s ~at 2 in
  let* m = read_digits s ~at:(at + 3) 2 in
  let* sec = read_digits s ~at:(at + 6) 2 in
  if has_text_at s ~at:(at + 2) ":" && has_text_at s ~at:(at + 5) ":" then
    Some (h, m, sec)
  else None

let compare_time (h, m, s) (h', m', s') =
  match Int.compare h h' with
  | 0 -> ( match Int.compare m m' with 0 -> Int.compare s s' | c -> c)
  | c -> c

let instant ~year ~month ~day time =
  Ptime.of_date_time ((year, month, day), (time, 0))

(* [Sun, 06 Nov 1994 08:49:37 GMT] *)
let parse_imf_fixdate s =
  let* _ = index_of_name Calendar.weekdays s ~at:0 in
  let* day = read_digits s ~at:5 2 in
  let* month = read_month s ~at:8 in
  let* year = read_digits s ~at:12 4 in
  let* time = read_time s ~at:17 in
  if
    has_text_at s ~at:3 ", " && has_text_at s ~at:7 " "
    && has_text_at s ~at:11 " " && has_text_at s ~at:16 " "
    && has_text_at s ~at:25 " GMT"
  then instant ~year ~month ~day time
  else None

(* [Sun Nov  6 08:49:37 1994], the day a digit after a space when it is one. *)
let parse_asctime s =
  let* _ = index_of_name Calendar.weekdays s ~at:0 in
  let* month = read_month s ~at:4 in
  let* day =
    if has_text_at s ~at:8 " " then read_digits s ~at:9 1
    else read_digits s ~at:8 2
  in
  let* time = read_time s ~at:11 in
  let* year = read_digits s ~at:20 4 in
  if
    has_text_at s ~at:3 " " && has_text_at s ~at:7 " "
    && has_text_at s ~at:10 " " && has_text_at s ~at:19 " "
  then instant ~year ~month ~day time
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
  let* time = read_time s ~at:(at + 10) in
  let (this_year, this_month, this_day), (now_time, _) =
    Ptime.to_date_time now
  in
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
          compare_time time now_time;
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
  then instant ~year ~month ~day time
  else None

let parse ~now s =
  match String.length s with
  | 29 -> parse_imf_fixdate s
  | 24 -> parse_asctime s
  | _ -> parse_rfc850 ~now s

(* Into its fixed 29 bytes rather than through Printf, since every answer
   carries one. *)
let to_string t =
  let (year, month, day), ((hh, mm, ss), _) = Ptime.to_date_time t in
  let b = Bytes.of_string "Thu, 01 Jan 1970 00:00:00 GMT" in
  let put_name at text = Bytes.blit_string text 0 b at 3 in
  let put_two_digits at n =
    Bytes.set b at (Char.chr (48 + (n / 10 mod 10)));
    Bytes.set b (at + 1) (Char.chr (48 + (n mod 10)))
  in
  put_name 0 Calendar.weekdays.(Ptime.weekday_num t);
  put_two_digits 5 day;
  put_name 8 Calendar.months.(month - 1);
  put_two_digits 12 (year / 100);
  put_two_digits 14 (year mod 100);
  put_two_digits 17 hh;
  put_two_digits 20 mm;
  put_two_digits 23 ss;
  Bytes.unsafe_to_string b
