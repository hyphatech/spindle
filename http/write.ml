module W = Eio.Buf_write

let write_fields oc headers =
  List.iter
    (fun (k, v) ->
      W.string oc k;
      W.string oc ": ";
      W.string oc v;
      W.string oc "\r\n")
    headers;
  W.string oc "\r\n"

let find_unwritable headers =
  List.find_opt (fun f -> not (Field.is_writable f)) headers

(* RFC 9110 §15: 100 to 599. *)
let response_head oc status headers =
  let n = Status.to_int status in
  if n < 100 || n > 599 then Error `Status
  else
    match find_unwritable headers with
    | Some (k, _) -> Error (`Field k)
    | None ->
        W.string oc "HTTP/1.1 ";
        W.string oc (string_of_int (Status.to_int status));
        W.char oc ' ';
        W.string oc (Status.reason status);
        W.string oc "\r\n";
        write_fields oc headers;
        Ok ()

let is_visible c = Char.code c > 0x20 && Char.code c < 0x7f

let request_head oc meth ~target headers =
  let m = Meth.to_string meth in
  if
    (not (Field.is_token m))
    || String.equal target ""
    || not (String.for_all is_visible target)
  then Error `Target
  else
    match find_unwritable headers with
    | Some (k, _) -> Error (`Field k)
    | None ->
        W.string oc m;
        W.char oc ' ';
        W.string oc target;
        W.string oc " HTTP/1.1\r\n";
        write_fields oc headers;
        Ok ()

let continue oc = W.string oc "HTTP/1.1 100 Continue\r\n\r\n"

let chunk oc s =
  if String.length s > 0 then (
    W.string oc (Printf.sprintf "%x\r\n" (String.length s));
    W.string oc s;
    W.string oc "\r\n")

let last_chunk oc = W.string oc "0\r\n\r\n"

(* Into its fixed 29 bytes rather than through Printf, since every answer
   carries one. *)
let date t =
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
