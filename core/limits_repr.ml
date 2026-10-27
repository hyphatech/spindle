(* The limits a server and a route are made with, read by the connection
   loop and by Test. *)

type server = {
  max_body : int;
  max_header_bytes : int;
  head_timeout : Mtime.Span.t;
  idle_timeout : Mtime.Span.t;
  body_timeout : Mtime.Span.t;
  min_body_rate : int;
  handler_timeout : Mtime.Span.t;
  send_timeout : Mtime.Span.t;
  discard_limit : int;
  linger : Mtime.Span.t;
  body_budget : int;
  max_connections : int;
  backlog : int;
  drain : Mtime.Span.t;
}

type route = {
  max_body : int option;
  body_timeout : Mtime.Span.t option;
  min_body_rate : int option;
  handler_timeout : Mtime.Span.t option;
}

let no_route =
  {
    max_body = None;
    body_timeout = None;
    min_body_rate = None;
    handler_timeout = None;
  }

(* A limit out of range is a constant written wrong where it is made,
   refused there rather than read as a server that serves nobody or a
   deadline that is always passed. *)
let check_limit ~who name ok shown =
  if not ok then
    invalid_arg (Printf.sprintf "%s: ~%s cannot be %s" who name shown)

let check_count ~who name ~least n =
  check_limit ~who name (n >= least) (string_of_int n)

(* A span is never negative, so a wait is out of range only at zero. *)
let check_wait ~who name span =
  check_limit ~who name
    (not (Mtime.Span.equal span Mtime.Span.zero))
    (Format.asprintf "%a" Mtime.Span.pp span)
