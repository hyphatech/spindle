module L = (val Logs.src_log Log.http : Logs.LOG)
module W = Eio.Buf_write
module Timeout = Eio.Time.Timeout

type 'a message =
  | Json : 'a Wiretype.t -> 'a message
  | Text : string message
  | Binary : string message

let json d = Json d
let text = Text
let binary = Binary

type ('c, 's) protocol = {
  subprotocol : string option;
  client : 'c message;
  server : 's message;
}

let protocol ?subprotocol ~client ~server () = { subprotocol; client; server }
let subprotocol p = p.subprotocol
let client p = p.client
let server p = p.server

type close_code =
  | Normal
  | Going_away
  | Protocol_error
  | Unsupported
  | Invalid_data
  | Policy
  | Too_big
  | Internal
  | Code of int

let code_to_int = function
  | Normal -> 1000
  | Going_away -> 1001
  | Protocol_error -> 1002
  | Unsupported -> 1003
  | Invalid_data -> 1007
  | Policy -> 1008
  | Too_big -> 1009
  | Internal -> 1011
  | Code n -> n

let code_of_int = function
  | 1000 -> Normal
  | 1001 -> Going_away
  | 1002 -> Protocol_error
  | 1003 -> Unsupported
  | 1007 -> Invalid_data
  | 1008 -> Policy
  | 1009 -> Too_big
  | 1011 -> Internal
  | n -> Code n

(* RFC 6455 §7.4: 1005, 1006 and 1015 are reported, never sent. *)
let is_sendable_code n =
  (n >= 1000 && n <= 1003)
  || (n >= 1007 && n <= 1014)
  || (n >= 3000 && n <= 4999)

(* §5.5: a control frame carries 125 bytes, and a close's code is two. *)
let max_close_reason_bytes = 123

(* §5.3: a frame's masking key. *)
let mask_bytes = 4

(* How long a closing socket waits for the other side: the handler to take
   the peer's close, or the peer to answer ours. *)
let close_wait = Mtime.Span.(1 * s)

type close = { code : close_code; reason : string }

type error =
  [ `Socket of [ `Closed of close ]
  | `Lost of string
  | `Undecodable of string
  | `Unwritable of string ]

(* How the socket ended, as it keeps it; what it answers is {!error}, the
   tags a handler joins with its own. *)
type ended =
  | Closed of close
  | Lost of string
  | Undecodable of string
  | Unwritable of string

let answered : ended -> [> error ] = function
  | Closed c -> `Socket (`Closed c)
  | Lost m -> `Lost m
  | Undecodable m -> `Undecodable m
  | Unwritable m -> `Unwritable m

let error_to_string : [< error ] -> string = function
  | `Socket (`Closed { code; reason = "" }) ->
      Printf.sprintf "closed, %d" (code_to_int code)
  | `Socket (`Closed { code; reason }) ->
      Printf.sprintf "closed, %d: %s" (code_to_int code) reason
  | `Lost m -> "lost: " ^ m
  | `Undecodable m -> "a message that could not be read: " ^ m
  | `Unwritable m -> "a message that could not be written: " ^ m

type data = Text_data of string | Binary_data of string

(* The peer's close comes after every message sent before it. *)
type received = Message of data | Close of close_code * string

type ('i, 'o) t = {
  incoming : 'i message;
  outgoing : 'o message;
  mask : (unit -> string) option;  (** a client's; a server masks nothing *)
  writer : W.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  send_timeout : Mtime.Span.t;
  write_lock : Eio.Mutex.t;
  received : received Eio.Stream.t;
      (** of capacity 0, so the reader reads no further until the handler takes
          what it read *)
  awaiting_handler : bool Atomic.t;
  ended : ended Eio.Promise.t;
  resolve_ended : ended Eio.Promise.u;
  close_frame : (close_code * string) option Atomic.t;
      (** the close this end sent or answered; no message may follow it (§5.5.1)
      *)
  close_begun : unit Eio.Promise.t;
  resolve_close_begun : unit Eio.Promise.u;
}

(* The first ending is the socket's. *)
let end_with t e = ignore (Eio.Promise.try_resolve t.resolve_ended e : bool)

(* ------------------------------------------------------------------ *)
(* Writing *)

(* Bounded by progress, not by time: [send_timeout] runs from the last byte
   the peer took, so a peer still reading a large message slowly is not cut
   off and one that stopped is. What is left to write is looked at ten times
   a limit, so the bound passes up to a tenth of it late, as the server's
   deadlines do. *)
let flush_bounded t () =
  let tick =
    Mtime.Span.of_uint64_ns
      (Int64.unsigned_div (Mtime.Span.to_uint64_ns t.send_timeout) 10L)
  in
  let rec watch ~left ~since =
    Eio.Time.Mono.sleep_span t.clock tick;
    let now = Eio.Time.Mono.now t.clock in
    let still_left = W.pending_bytes t.writer in
    if still_left < left then watch ~left:still_left ~since:now
    else if Mtime.Span.is_shorter (Mtime.span since now) ~than:t.send_timeout
    then watch ~left ~since
    else
      Error
        (Lost
           (Format.asprintf "nothing written was taken for %a" Mtime.Span.pp
              t.send_timeout))
  in
  match
    Eio.Fiber.first
      (fun () -> Ok (W.flush t.writer))
      (fun () ->
        watch ~left:(W.pending_bytes t.writer)
          ~since:(Eio.Time.Mono.now t.clock))
  with
  | flushed -> flushed
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex -> Error (Lost (Printexc.to_string ex))

let write t opcode payload =
  let is_data =
    match opcode with
    | Frame.Text | Frame.Binary | Frame.Continuation -> true
    | Frame.Close | Frame.Ping | Frame.Pong -> false
  in
  (* Judged under the lock, so a frame that waited for it sees what the one
     before it did. *)
  Eio.Mutex.use_ro t.write_lock @@ fun () ->
  match (Eio.Promise.peek t.ended, Atomic.get t.close_frame) with
  | Some e, _ -> Error e
  | None, Some (code, reason) when is_data -> Error (Closed { code; reason })
  | None, (Some _ | None) -> (
      match Option.map (fun f -> f ()) t.mask with
      | Some key when String.length key <> mask_bytes ->
          let e =
            Lost
              (Printf.sprintf "a mask of %d bytes, where a frame takes %d"
                 (String.length key) mask_bytes)
          in
          L.err (fun m -> m "%s" (error_to_string (answered e)));
          end_with t e;
          Error e
      | mask -> (
          match
            Frame.write t.writer ?mask ~fin:true opcode payload
              ~flush:(flush_bounded t)
          with
          | Ok () -> Ok ()
          | Error e ->
              end_with t e;
              Error e
          (* §5.2: the peer reads the rest of the declared length as this
             frame's payload, so after a frame cut off nothing may follow. *)
          | exception (Eio.Cancel.Cancelled _ as ex) ->
              end_with t (Lost "a send was cancelled partway through its frame");
              raise ex))

let close_payload code reason =
  let b = Bytes.create 2 in
  Bytes.set_uint16_be b 0 (code_to_int code);
  Bytes.to_string b ^ reason

let close ?(code = Normal) ?(reason = "") t =
  let code =
    if is_sendable_code (code_to_int code) then code
    else (
      L.err (fun m ->
          m "a socket closed with %d, which no endpoint may send"
            (code_to_int code));
      Internal)
  in
  let reason =
    if
      String.length reason <= max_close_reason_bytes
      && String.is_valid_utf_8 reason
    then reason
    else (
      L.err (fun m ->
          m "a socket closed with a reason no close can carry: %d bytes%s"
            (String.length reason)
            (if String.is_valid_utf_8 reason then "" else ", not UTF-8"));
      "")
  in
  if Atomic.compare_and_set t.close_frame None (Some (code, reason)) then (
    ignore (Eio.Promise.try_resolve t.resolve_close_begun () : bool);
    ignore
      (write t Frame.Close (close_payload code reason) : (unit, ended) result))

type 'o encoded = (Frame.opcode * string, string) result

(* RFC 6455 §8.1: a text frame is UTF-8, and a peer fails the connection
   on one that is not, so none is written. *)
let encode : type a. a message -> a -> a encoded =
 fun message v ->
  match message with
  | Json d -> (
      match Wiretype.encode d v with
      | Ok s -> Ok (Frame.Text, s)
      | Error m -> Error (Wiretype.Unwritable.to_string m))
  | Text when String.is_valid_utf_8 v -> Ok (Frame.Text, v)
  | Text -> Error "a text message that is not UTF-8"
  | Binary -> Ok (Frame.Binary, v)

let send_encoded t encoded =
  Result.map_error answered
    (match encoded with
    | Ok (opcode, payload) -> write t opcode payload
    | Error m -> Error (Unwritable m))

let send t v = send_encoded t (encode t.outgoing v)

(* ------------------------------------------------------------------ *)
(* Receiving *)

let decode_data : type a. a message -> data -> (a, ended) result =
 fun message data ->
  match (message, data) with
  | Json d, Text_data s ->
      Result.map_error
        (fun problems ->
          Undecodable
            (String.concat "; " (List.map Wiretype.Problem.to_string problems)))
        (Wiretype.decode d s)
  | Text, Text_data s -> Ok s
  | Binary, Binary_data s -> Ok s
  (* Unreachable: the reader refuses a kind the socket does not carry. *)
  | (Json _ | Text), Binary_data _ -> Error (Undecodable "a binary message")
  | Binary, Text_data _ -> Error (Undecodable "a text message")

(* A kind this end does not take is closed with 1003 (§7.4.1). *)
let carries_kind : type a. a message -> Frame.opcode -> bool =
 fun message kind ->
  match (message, kind) with
  | (Json _ | Text), Frame.Text | Binary, Frame.Binary -> true
  | (Json _ | Text | Binary), _ -> false

let result_of_received t = function
  | Message data -> decode_data t.incoming data
  | Close (code, reason) -> Error (Closed { code; reason })

(* A message received before the socket ended is still read. *)
let receive t =
  Result.map_error answered
  @@
  match Eio.Stream.take_nonblocking t.received with
  | Some r -> result_of_received t r
  | None -> (
      match Eio.Promise.peek t.ended with
      | Some e -> Error e
      | None -> (
          match
            Eio.Fiber.first
              (fun () -> `Received (Eio.Stream.take t.received))
              (fun () -> `Ended (Eio.Promise.await t.ended))
          with
          | `Received r -> result_of_received t r
          | `Ended e -> (
              match Eio.Stream.take_nonblocking t.received with
              | Some r -> result_of_received t r
              | None -> Error e)))

(* ------------------------------------------------------------------ *)
(* Reading frames *)

type side = Server_side | Client_side

(* The peer broke the protocol: it is told why, and the socket ends. *)
let fail t code reason =
  close ~code ~reason t;
  Closed { code; reason }

(* §5.5.1: an empty close is 1005, and one byte is not a code. *)
let close_of_payload payload =
  match String.length payload with
  | 0 -> Ok (Code 1005, "")
  | 1 -> Error (Protocol_error, "a close frame of one byte")
  | _ ->
      let n = String.get_uint16_be payload 0 in
      let reason = String.sub payload 2 (String.length payload - 2) in
      if not (is_sendable_code n) then
        Error (Protocol_error, Printf.sprintf "a close with code %d" n)
      else if not (String.is_valid_utf_8 reason) then
        Error (Invalid_data, "a close reason that is not UTF-8")
      else Ok (code_of_int n, reason)

let hand_over t r =
  Atomic.set t.awaiting_handler true;
  Fun.protect
    ~finally:(fun () -> Atomic.set t.awaiting_handler false)
    (fun () -> Eio.Stream.add t.received r)

(* A frame's length is what the peer claims, so a message's buffer starts
   at most this large and grows as its bytes arrive: fourteen bytes would
   otherwise hold [max_message]. *)
let first_buffer_bytes = 4096

let read_frames t ~side ~max_message ~heard reader =
  (* [partial] is a fragmented message still arriving, with its kind. *)
  let rec next partial =
    match Frame.read_header reader with
    | Error m -> fail t Protocol_error m
    | Ok h -> (
        heard ();
        let masked = Option.is_some h.mask in
        match (side, masked) with
        | Server_side, false -> fail t Protocol_error "an unmasked frame"
        | Client_side, true -> fail t Protocol_error "a masked frame"
        | (Server_side | Client_side), _ -> (
            let length_so_far =
              match partial with Some (_, b) -> Buffer.length b | None -> 0
            in
            (* Subtracted, not added: a frame may declare a length near
               [max_int], and the sum would wrap past the check. *)
            match h.opcode with
            | (Frame.Text | Frame.Binary | Frame.Continuation)
              when h.length > max_message - length_so_far ->
                fail t Too_big
                  (Printf.sprintf "a message longer than %d bytes" max_message)
            | Frame.Ping | Frame.Pong | Frame.Close ->
                let b = Buffer.create h.length in
                Frame.read_payload reader h ~on_piece:heard b;
                control partial h.opcode (Buffer.contents b)
            | Frame.Text | Frame.Binary -> (
                match partial with
                | Some _ ->
                    fail t Protocol_error
                      "a new message before the last one ended"
                | None ->
                    let b = Buffer.create (min h.length first_buffer_bytes) in
                    Frame.read_payload reader h ~on_piece:heard b;
                    if h.fin then deliver h.opcode b
                    else next (Some (h.opcode, b)))
            | Frame.Continuation -> (
                match partial with
                | None -> fail t Protocol_error "a continuation of nothing"
                | Some (kind, b) ->
                    Frame.read_payload reader h ~on_piece:heard b;
                    if h.fin then deliver kind b else next partial)))
  and control partial opcode payload =
    match opcode with
    | Frame.Ping -> (
        match write t Frame.Pong payload with
        | Ok () -> next partial
        | Error e -> e)
    | Frame.Close -> (
        match close_of_payload payload with
        | Error (code, reason) -> fail t code reason
        | Ok (code, reason) ->
            (* The handler is given the peer's close, after every message
               before it, unless this end began the close (§5.5.1). *)
            if Option.is_none (Atomic.get t.close_frame) then
              ignore
                (Timeout.run (Timeout.v t.clock close_wait) (fun () ->
                     Ok
                       (Eio.Fiber.first
                          (fun () -> hand_over t (Close (code, reason)))
                          (fun () -> Eio.Promise.await t.close_begun)))
                  : (unit, [ `Timeout ]) result);
            (* Answered with the code it named, unless ours has gone. *)
            (if Atomic.compare_and_set t.close_frame None (Some (code, reason))
             then
               let answer =
                 match code with Code 1005 -> "" | c -> close_payload c ""
               in
               ignore (write t Frame.Close answer : (unit, ended) result));
            Closed { code; reason })
    | Frame.Pong | Frame.Text | Frame.Binary | Frame.Continuation ->
        next partial
  and deliver kind b =
    let s = Buffer.contents b in
    match kind with
    | Frame.Text when not (String.is_valid_utf_8 s) ->
        fail t Invalid_data "a text message that is not UTF-8"
    | _ when not (carries_kind t.incoming kind) ->
        fail t Unsupported "a kind of message this socket does not carry"
    | Frame.Text ->
        hand_over t (Message (Text_data s));
        next None
    | _ ->
        hand_over t (Message (Binary_data s));
        next None
  in
  (* Anything else the flow raises, a TLS alert say, is the connection
     failing beneath the socket. *)
  match next None with
  | ended -> ended
  | exception (End_of_file | Eio.Io _) ->
      Lost "the connection ended without a close"
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex -> Lost (Printexc.to_string ex)

(* Pings after [keep_alive] without a byte of a frame, and gives up at
   twice that. A peer still sending a large message slowly is heard, and
   time spent waiting for the handler is not the peer's silence. *)
let ping_while_silent t ~keep_alive ~last_heard_at =
  let give_up = Mtime.Span.(2 * keep_alive) in
  let rec watch () =
    if Atomic.get t.awaiting_handler then
      Atomic.set last_heard_at (Eio.Time.Mono.now t.clock);
    let silent =
      Mtime.span (Atomic.get last_heard_at) (Eio.Time.Mono.now t.clock)
    in
    if not (Mtime.Span.is_shorter silent ~than:give_up) then
      Lost (Format.asprintf "nothing heard for %a" Mtime.Span.pp silent)
    else if not (Mtime.Span.is_shorter silent ~than:keep_alive) then (
      match write t Frame.Ping "" with
      | Error e -> e
      | Ok () ->
          Eio.Time.Mono.sleep_span t.clock (Mtime.Span.abs_diff give_up silent);
          watch ())
    else (
      Eio.Time.Mono.sleep_span t.clock (Mtime.Span.abs_diff keep_alive silent);
      watch ())
  in
  watch ()

(* A ping well inside the half a minute after which proxies and load
   balancers commonly drop a silent connection. *)
let default_keep_alive = Mtime.Span.(15 * s)

(* A mebibyte, as a request body's default limit is. *)
let default_max_message = 1 lsl 20

let run ~side ~mask ?(keep_alive = default_keep_alive)
    ?(max_message = default_max_message) ~incoming ~outgoing (c : Connection.t)
    f =
  let ended, resolve_ended = Eio.Promise.create () in
  let close_begun, resolve_close_begun = Eio.Promise.create () in
  let t =
    {
      incoming;
      outgoing;
      mask;
      writer = c.writer;
      clock = c.clock;
      send_timeout = c.send_timeout;
      write_lock = Eio.Mutex.create ();
      received = Eio.Stream.create 0;
      awaiting_handler = Atomic.make false;
      ended;
      resolve_ended;
      close_frame = Atomic.make None;
      close_begun;
      resolve_close_begun;
    }
  in
  let last_heard_at = Atomic.make (Eio.Time.Mono.now c.clock) in
  let heard () = Atomic.set last_heard_at (Eio.Time.Mono.now c.clock) in
  let close_and_wait close_with =
    Option.iter (fun (code, reason) -> close ~code ~reason t) close_with;
    ignore
      (Timeout.run (Timeout.v c.clock close_wait) (fun () ->
           Ok (Eio.Promise.await ended))
        : (ended, [ `Timeout ]) result)
  in
  Eio.Switch.run @@ fun sw ->
  (* Daemons, so the handler returning ends them. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      end_with t
        (Eio.Fiber.first
           (fun () -> read_frames t ~side ~max_message ~heard c.reader)
           (fun () -> ping_while_silent t ~keep_alive ~last_heard_at));
      `Stop_daemon);
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Promise.await c.stopping;
      close ~code:Going_away ~reason:"The server is stopping." t;
      `Stop_daemon);
  match f t with
  | Ok _ as ok ->
      close_and_wait (Some (Normal, ""));
      ok
  | Error (`Undecodable _) as e ->
      close_and_wait
        (Some (Invalid_data, "A message this socket could not read."));
      e
  | Error (`Socket _ | `Lost _) as e ->
      close_and_wait None;
      e
  (* [`Unwritable], and whatever the handler ended with of its own: our end
     failed, and the peer is told so. *)
  | Error _ as e ->
      close_and_wait (Some (Internal, "Something went wrong at our end."));
      e
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      close_and_wait (Some (Internal, "Something went wrong at our end."));
      Printexc.raise_with_backtrace ex bt

module Private = struct
  let accept_key = Frame.accept_key

  let run_server ?keep_alive ?max_message p c f =
    run ~side:Server_side ~mask:None ?keep_alive ?max_message ~incoming:p.client
      ~outgoing:p.server c f

  let run_client ?keep_alive ?max_message ~mask p c f =
    run ~side:Client_side ~mask:(Some mask) ?keep_alive ?max_message
      ~incoming:p.server ~outgoing:p.client c f
end
