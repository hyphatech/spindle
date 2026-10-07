(* Another server, for a test that stands one in for OGS or the engine: it
   answers each request as the test's function says, read and written by
   spindle_http, the same reader and writer the real server and client use.
   The function may take its time, or never answer -- a hung engine is one
   of the things a test stands in. *)

module Head = Spindle_http.Head
module Framing = Spindle_http.Framing
module Write = Spindle_http.Write
module Field = Spindle_http.Field

type request = {
  meth : Spindle_http.Meth.t;
  path : string;
  query : (string * string list) list;
  headers : (string * string) list;
  body : string;
}

type reply = {
  status : Spindle_http.Status.t;
  headers : (string * string) list;
  body : string;
}

let reply ?(headers = []) status body = { status; headers; body }
let header (r : request) name = Field.find r.headers name

let answer flow (r : reply) =
  Eio.Buf_write.with_flow flow (fun oc ->
      match
        Write.response_head oc r.status
          (r.headers
          @ [ ("content-length", string_of_int (String.length r.body)) ])
      with
      | Ok () -> Eio.Buf_write.string oc r.body
      | Error (`Field name) -> Alcotest.failf "a stub's field %S" name
      | Error `Status -> Alcotest.fail "a stub's status")

let body_of ic head =
  match Framing.of_request head with
  | Error _ -> ""
  | Ok framing -> (
      match
        Framing.read (Framing.reader framing ic ~max_trailer:65_536)
          ~max:16_777_216 ~reserve:(fun _ -> true)
      with
      | Ok body -> body
      | Error _ -> "")

(* The port first, then the answering: a stub whose own state holds its
   port needs the one before it can say the other. *)
let listen ~sw ~net =
  let socket =
    Eio.Net.listen net ~sw ~backlog:16 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | `Unix _ -> Alcotest.fail "expected a TCP socket"
  in
  let start respond =
    Eio.Fiber.fork_daemon ~sw (fun () ->
        Eio.Net.run_server socket ~on_error:ignore (fun flow _ ->
            let ic = Eio.Buf_read.of_flow flow ~max_size:1_048_576 in
            let rec next () =
              match Head.Request.read ~max:65_536 ic with
              | Error _ -> ()
              | Ok head ->
                  let body = body_of ic head in
                  let uri = Uri.of_string head.target in
                  answer flow
                    (respond
                       {
                         meth = head.meth;
                         path = Uri.path uri;
                         query = Uri.query uri;
                         headers = head.headers;
                         body;
                       });
                  if Head.Request.keep_alive head then next ()
            in
            next ()))
  in
  (port, start)

let serve ~sw ~net respond =
  let port, start = listen ~sw ~net in
  start respond;
  port
