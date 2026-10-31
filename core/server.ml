(* The connection loop reads and writes every byte itself: where a head and a
   body end, how an answer is framed, whether a connection carries another
   request, and how long anything may take. *)

module Local = Spindle_http.Local
module Status = Spindle_http.Status
module Meth = Spindle_http.Meth
module Head = Spindle_http.Private.Head
module Framing = Spindle_http.Private.Framing
module Field = Spindle_http.Field
module Write = Spindle_http.Private.Write
module Timeout = Eio.Time.Timeout
module Trace = Spindle_http.Trace
module L = (val Logs.src_log Log.http : Logs.LOG)

(* An IPv4 client reached through the IPv6 wildcard arrives as
   ::ffff:a.b.c.d, and is named by its IPv4 address. *)
let v4_mapped_prefix = "\000\000\000\000\000\000\000\000\000\000\255\255"

let peer_of_address = function
  | `Tcp (addr, _) ->
      let raw = (addr : Eio.Net.Ipaddr.v4v6 :> string) in
      let addr =
        if
          String.length raw = 16
          && String.starts_with ~prefix:v4_mapped_prefix raw
        then Eio.Net.Ipaddr.of_raw (String.sub raw 12 4)
        else addr
      in
      Format.asprintf "%a" Eio.Net.Ipaddr.pp addr
  | `Unix path -> "unix:" ^ path

(* A trusted proxy's request id is kept, so one search finds the request at
   both ends. *)
let max_request_id_length = 64

let is_usable_request_id s =
  let n = String.length s in
  n > 0 && n <= max_request_id_length
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true
         | _ -> false)
       s

(* A range, since a fleet behind a load balancer is a subnet whose members
   come and go; anything else, such as [unix:<path>], is a peer as printed. *)
type proxy_header = Request.proxy_header = X_forwarded_for | Forwarded
type proxy = Range of Ipaddr.Prefix.t | Peer of string

(* Only a Unix peer is taken as printed: anything else that reads as no
   address -- [10.0.0.0/33], a typo -- would trust nobody, without a word. *)
let proxy_of_string s =
  match Ipaddr.Prefix.of_string s with
  | Ok range -> Range range
  | Error _ -> (
      match Ipaddr.of_string s with
      | Ok addr -> Range (Ipaddr.Prefix.of_addr addr)
      | Error _ when String.starts_with ~prefix:"unix:" s -> Peer s
      | Error _ ->
          invalid_arg
            (Printf.sprintf
               "Spindle.Server: trusted proxy %S is no address, range or \
                unix:<path>"
               s))

let check_count = Limits_repr.check_count ~who:"Spindle.Server"
let check_wait = Limits_repr.check_wait ~who:"Spindle.Server"

module Limits = struct
  type t = Limits_repr.server

  let make ?(max_body = 1_048_576) ?(max_header_bytes = 16_384)
      ?(head_timeout = Mtime.Span.(10 * s))
      ?(idle_timeout = Mtime.Span.(60 * s))
      ?(body_timeout = Mtime.Span.(20 * s)) ?(min_body_rate = 500)
      ?(handler_timeout = Mtime.Span.(60 * s))
      ?(send_timeout = Mtime.Span.(30 * s)) ?(discard_limit = 65_536)
      ?(linger = Mtime.Span.s) ?(body_budget = 67_108_864)
      ?(max_connections = 512) ?(backlog = 128) ?(drain = Mtime.Span.(10 * s))
      () =
    check_count "max_body" ~least:0 max_body;
    check_count "max_header_bytes" ~least:1 max_header_bytes;
    check_count "min_body_rate" ~least:1 min_body_rate;
    check_count "discard_limit" ~least:0 discard_limit;
    check_count "body_budget" ~least:0 body_budget;
    check_count "max_connections" ~least:1 max_connections;
    check_wait "head_timeout" head_timeout;
    check_wait "idle_timeout" idle_timeout;
    check_wait "body_timeout" body_timeout;
    check_wait "send_timeout" send_timeout;
    check_wait "handler_timeout" handler_timeout;
    ({
       max_body;
       max_header_bytes;
       head_timeout;
       idle_timeout;
       body_timeout;
       min_body_rate;
       handler_timeout;
       send_timeout;
       discard_limit;
       linger;
       body_budget;
       max_connections;
       backlog;
       drain;
     }
      : t)

  let default = make ()
end

let is_trusted proxies who =
  match proxies with
  | [] -> false
  | proxies ->
      let addr = Result.to_option (Ipaddr.of_string who) in
      List.exists
        (function
          | Range range -> (
              match addr with
              | Some addr -> Ipaddr.Prefix.mem addr range
              | None -> false)
          | Peer peer -> String.equal peer who)
        proxies

(* An element as a proxy may write it -- [1.2.3.4:5678], [[2001:db8::1]:80],
   [[2001:db8::1]] -- is its address alone, as Forwarded's node is: a client
   is one client whichever port it came from, or a rate limit keyed by it
   would limit nobody. One that is no address is kept as it came. *)
let address_of_element e =
  match Ipaddr.with_port_of_string ~default:0 e with
  | Ok (address, _) -> Ipaddr.to_string address
  | Error (`Msg _) -> e

(* The rightmost address not a trusted proxy's: everything to its left was
   written by the client. *)
let forwarded_for ~trusted value =
  List.rev_map address_of_element (Field.elements value)
  |> List.find_opt (fun a -> not (is_trusted trusted a))

(* The same walk through Forwarded's [for] nodes; an unknown or hidden hop
   ends it. *)
let forwarded_client ~trusted lines =
  match Spindle_http.Forwarded.parse (String.concat ", " lines) with
  | Error _ -> None
  | Ok elements ->
      let rec walk = function
        | [] -> None
        | (e : Spindle_http.Forwarded.element) :: rest -> (
            match e.for_ with
            | Some { name = Address a; port = _ } when is_trusted trusted a ->
                walk rest
            | Some { name = Address a; port = _ } -> Some a
            | Some { name = Unknown | Obfuscated _; port = _ } | None -> None)
      in
      walk (List.rev elements)

type limits = {
  max_body : int;
  send_timeout : Mtime.Span.t;
  max_header_bytes : int;
  head_timeout : Mtime.Span.t;
  idle_timeout : Mtime.Span.t;
  body_timeout : Mtime.Span.t;
  min_body_rate : int;
  handler_timeout : Mtime.Span.t;
  discard_limit : int;
  linger : Mtime.Span.t;
  body_budget : int;
  trusted_proxies : proxy list;
  proxy_header : Request.proxy_header;
}

(* Shared by every domain the server runs on. A stream of no length leaves
   [in_flight] once its head has gone; [on_stop] is how its producer learns
   to end. *)
type state = {
  mutable in_flight : int; [@atomic]
  mutable stopping : bool; [@atomic]
  mutable body_bytes_reserved : int; [@atomic]
  drained : unit Eio.Promise.t;
  resolve_drained : unit Eio.Promise.u;
  stop_begun : unit Eio.Promise.t;
      (** so a taken-over connection can say goodbye while it still can *)
  resolve_stop_begun : unit Eio.Promise.u;
}

let resolve_drained state =
  ignore (Eio.Promise.try_resolve state.resolve_drained () : bool)

let while_in_flight state f =
  ignore (Atomic.Loc.fetch_and_add [%atomic.loc state.in_flight] 1 : int);
  Fun.protect
    ~finally:(fun () ->
      let before =
        Atomic.Loc.fetch_and_add [%atomic.loc state.in_flight] (-1)
      in
      if before = 1 && state.stopping then resolve_drained state)
    f

(* Under OpenTelemetry's names where it has them. The body budget is sampled
   when the metrics are read, so it costs a request nothing. *)
type instruments = {
  duration : Metrics.histogram;
  active : Metrics.gauge;
  connections : Metrics.gauge;
}

let make_instruments metrics state =
  Metrics.sampled metrics ~help:"Bytes of request bodies the server holds"
    ~unit:"bytes" "spindle.server.body_budget.used" (fun () ->
      [ ([], float_of_int state.body_bytes_reserved) ]);
  {
    duration =
      Metrics.histogram metrics ~help:"How long a request took to answer"
        ~unit:"seconds"
        ~labels:
          [ "http.request.method"; "http.route"; "http.response.status_code" ]
        "http.server.request.duration";
    active =
      Metrics.gauge metrics ~help:"Requests being answered"
        "http.server.active_requests";
    connections =
      Metrics.gauge metrics ~help:"Connections open"
        "spindle.server.open_connections";
  }

let make_request ~read_clock ~limits ~peer (head : Head.Request.t) =
  let header = Field.find head.headers in
  let proxied = is_trusted limits.trusted_proxies peer in
  let id =
    match header "x-request-id" with
    | Some v when proxied && is_usable_request_id v -> v
    | Some _ | None -> Log.fresh_id ()
  in
  (* Every X-Forwarded-For line: a proxy may add its own rather than join the
     client's. *)
  let client =
    match (limits.proxy_header, Field.all head.headers "x-forwarded-for") with
    | Request.X_forwarded_for, (_ :: _ as lines) when proxied ->
        Option.value
          (forwarded_for ~trusted:limits.trusted_proxies
             (String.concat "," lines))
          ~default:peer
    | Request.Forwarded, _ when proxied ->
        Option.value
          (forwarded_client ~trusted:limits.trusted_proxies
             (Field.all head.headers "forwarded"))
          ~default:peer
    | (Request.X_forwarded_for | Request.Forwarded), _ -> peer
  in
  Request.make ~id ~peer ~client_ip:client ~proxied
    ~proxy_header:limits.proxy_header ~version:head.version ?host:head.host
    ~headers:head.headers ~read_clock head.meth head.target

let elapsed clock since = Mtime.span since (Eio.Time.Mono.now clock)

(* A log line's duration is in nanoseconds, the unit collectors read one in. *)
let nanoseconds span = Int64.to_int (Mtime.Span.to_uint64_ns span)

(* OpenTelemetry's method label: a method HTTP names, or [other] for any
   other, since every label value is a series kept for the process's life. *)
let meth_label ~other req =
  match Request.meth req with
  | ( `GET | `HEAD | `POST | `PUT | `DELETE | `OPTIONS | `PATCH | `CONNECT
    | `TRACE ) as m ->
      Meth.to_string m
  | `Other _ -> other

(* From what goes out: the wire's status and refusal, and the bytes after the
   head. The path and never the query, which is where a callback carries a
   code. *)
let rec log_access ~instruments req ~duration (answered : App.answered)
    (wire : Wire.t) =
  let status = Status.to_int wire.status in
  let bytes =
    match wire.body with
    | Wire.Bytes s -> String.length s
    | Wire.Counted (n, _) -> n
    | Wire.Nothing | Wire.Chunks _ | Wire.Until_close _ | Wire.Connection _ -> 0
  in
  let fields =
    [
      ("http.request.method", `String (Meth.to_string (Request.meth req)));
      ("url.path", `String (Request.path req));
      ("http.response.status_code", `Int status);
      ("duration", `Int (nanoseconds duration));
      ("http.response.body.size", `Int bytes);
    ]
    @ (match answered.route with
      | Some p -> [ ("http.route", `String p) ]
      | None -> [])
    @
    match wire.refused with
    | Some f ->
        [ ("spindle.refusal.code", `String (Refusal.Code.name f.Refusal.code)) ]
    | None -> []
  in
  L.msg answered.access_log (fun m ->
      m "%s %s %d"
        (Meth.to_string (Request.meth req))
        (Request.path req) status ~tags:(Log.tags fields));
  name_span req answered ~status (List.remove_assoc "duration" fields);
  Option.iter (record_duration req answered ~status ~duration) instruments

and record_duration req (answered : App.answered) ~status ~duration instruments
    =
  Metrics.observe instruments.duration
    [
      meth_label ~other:"_OTHER" req;
      Option.value answered.route ~default:"";
      string_of_int status;
    ]
    (* In seconds, as OpenTelemetry's histogram counts it. *)
    (Mtime.Span.to_float_ns duration /. 1e9)

(* Named by route, never by path. A 5xx is the server's failure; a 4xx is the
   client's. *)
and name_span req (answered : App.answered) ~status fields =
  let span = Trace.current () in
  let meth = meth_label ~other:"HTTP" req in
  Trace.rename span
    (match answered.route with Some p -> meth ^ " " ^ p | None -> meth);
  Trace.add span fields;
  if status >= 500 then Trace.fail span (string_of_int status)

(* [Wire.render] has already made a 500 of any response it cannot write, so
   this is the framework's bug: nothing is written and the connection
   closes. *)
exception Unwritable of string

let write_head oc status headers =
  match Write.response_head oc status headers with
  | Ok () -> ()
  | Error (`Field name) ->
      raise (Unwritable (Printf.sprintf "the field %S" name))
  | Error `Status ->
      raise (Unwritable (Printf.sprintf "the status %d" (Status.to_int status)))

(* A client that took nothing written for the send limit. It ends the
   connection, never answers. *)
exception Stalled

(* A connection's output. An answer is written into [buf] and sent by the
   fiber that flushes it: the socket takes most writes at once, so a flush
   is one write, with no fiber woken to make it and no promise to wait on.
   One fiber flushes at a time -- two draining at once would send the same
   bytes twice -- and nothing needs a lock for it: the connection's own
   fiber flushes between exchanges and while a handler reads its body, a
   stream's sends take turns under the stream's lock and its last bytes go
   once its producer has returned, and a takeover's handler, which flushes
   through [Buf_write] itself, is handed [buf] with a fiber that copies it
   ([take_over]) once the server has flushed for the last time. *)
type output = {
  buf : Eio.Buf_write.t;
  flow : Eio.Flow.sink_ty Eio.Resource.t;
  sw : Eio.Switch.t;
  mutable copied : unit Eio.Promise.t option;
  mutable write_error : exn option;
}

(* A write the socket refuses, or a sink that has ended, aborts the buffer, so whatever writes next is
   refused too, and is raised to the flush that met it; it is kept, so the
   connection ends on it rather than on whatever the refusal raised next. *)
let send_pending ~deadline out =
  while Eio.Buf_write.has_pending_output out.buf do
    match
      Eio.Flow.single_write out.flow (Eio.Buf_write.await_batch out.buf)
    with
    | n ->
        Deadline.progress deadline n;
        Eio.Buf_write.shift out.buf n
    | exception ((Eio.Io _ | End_of_file) as ex) ->
        out.write_error <- Some ex;
        Eio.Buf_write.abort out.buf;
        raise ex
  done

(* Bounded by progress, not by time: a client still reading a large answer
   slowly is not cut off. *)
let flush ~limits ~deadline out =
  Deadline.arm_since_last deadline limits.send_timeout;
  let flushed = Deadline.wait deadline (fun () -> send_pending ~deadline out) in
  Deadline.clear deadline;
  match flushed with Some () -> () | None -> raise Stalled

(* From here the takeover's handler writes and flushes, and the server only
   waits for the copying to end. A write the socket refuses aborts the
   buffer rather than raising, and the server raises it once the takeover
   ends ([with_output]). *)
let take_over ~deadline out =
  let copied, all_copied = Eio.Promise.create () in
  out.copied <- Some copied;
  Eio.Fiber.fork ~sw:out.sw (fun () ->
      let rec copy () =
        match Eio.Buf_write.await_batch out.buf with
        | iovecs -> (
            match Eio.Flow.single_write out.flow iovecs with
            | n ->
                Deadline.progress deadline n;
                Eio.Buf_write.shift out.buf n;
                copy ()
            | exception (Eio.Io _ as ex) ->
                out.write_error <- Some ex;
                Eio.Buf_write.abort out.buf)
        | exception End_of_file -> ()
      in
      copy ();
      Eio.Promise.resolve all_copied ());
  out.buf

(* ------------------------------------------------------------------ *)
(* Streams *)

(* A stream of a declared length is never written past it, and one that sends
   another number of bytes closes its connection: a length the body disagrees
   with is the next request's first bytes, or a client waiting forever. *)
type stream_framing = Chunked | Raw | Counted of int

exception Overran

(* Answers whether the connection can carry another request: only a stream
   that finished cleanly leaves it fit. Its second access line says how it
   ended: [finished], [client gone] after a failed write, or [connection
   closed] on cancellation, which is how a stopping server ends it. *)
let write_stream ?gzip ~clock ~limits ~deadline ~framing req out
    (stream : Response.stream) =
  let is_chunked =
    match framing with Chunked -> true | Raw | Counted _ -> false
  in
  let started = Eio.Time.Mono.now clock in
  let log_end how =
    L.info (fun m ->
        m "stream on %s ended: %s" (Request.path req) how
          ~tags:
            (Log.tags
               [
                 ("url.path", `String (Request.path req));
                 ("duration", `Int (nanoseconds (elapsed clock started)));
                 ("spindle.stream.ended", `String how);
               ]))
  in
  let failure = ref None in
  let bytes_left =
    ref (match framing with Counted n -> n | Chunked | Raw -> 0)
  in
  let send_raw s =
    match !failure with
    | Some _ -> Error Response.Gone
    | None when String.length s = 0 -> Ok ()
    | None -> (
        let s, overran =
          match framing with
          | Counted _ when String.length s > !bytes_left ->
              (String.sub s 0 !bytes_left, true)
          | Counted _ | Chunked | Raw -> (s, false)
        in
        match
          if is_chunked then Write.chunk out.buf s
          else Eio.Buf_write.string out.buf s;
          flush ~limits ~deadline out
        with
        | () ->
            bytes_left := !bytes_left - String.length s;
            if overran then (
              failure := Some Overran;
              Error Response.Gone)
            else Ok ()
        | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
        | exception ex ->
            failure := Some ex;
            Request_repr.mark_client_gone req;
            Error Response.Gone)
  in
  (* Encoded here, where every byte is sent, so a keep-alive's filler is part
     of the one gzip stream rather than raw bytes inside it. *)
  let encoder = Option.map (fun level -> Gzip.create ~level) gzip in
  let send s =
    match encoder with
    | None -> send_raw s
    | Some _ when String.length s = 0 -> Ok ()
    | Some g -> send_raw (Gzip.write g s)
  in
  let gzip_trailer () =
    match encoder with Some g -> Gzip.finish g | None -> ""
  in
  let log_length_mismatch () =
    match framing with
    | Counted n ->
        L.err (fun m ->
            m
              "stream on %s said it was %d bytes and sent %s, so its \
               connection is closed"
              (Request.path req) n
              (if !bytes_left > 0 then string_of_int (n - !bytes_left)
               else "more"))
    | Chunked | Raw -> ()
  in
  (* Sends take turns under a lock of this stream's own, whether a producer
     sends from several fibers or a filler runs beside it: a deadline ends
     one wait at a time, so a second flush beside the first would leave one
     of them waiting on a client that stopped reading, for ever. *)
  let lock = Eio.Mutex.create () in
  (* When the stream last sent, in the clock's nanoseconds: an immediate, so
     a send moves it without allocating. *)
  let now_ns () = Int64.to_int (Mtime.to_uint64_ns (Eio.Time.Mono.now clock)) in
  let last_sent = ref (Int64.to_int (Mtime.to_uint64_ns started)) in
  (* Once [produce] has returned the connection is the loop's again, and a
     byte sent then -- from a fiber the route left behind -- lands between
     this answer and the next. *)
  let produced = ref false in
  let send s =
    Eio.Mutex.use_ro lock (fun () ->
        if !produced then (
          L.warn (fun m ->
              m
                "%s sent on its stream after its producer had returned, which \
                 sent nothing"
                (Request.path req));
          Error Response.Gone)
        else
          let sent = send s in
          last_sent := now_ns ();
          sent)
  in
  (* A filler that cannot be written stops, and says the client has gone, so
     a producer waiting on [Request.client_gone] ends now; one that is not
     learns it at its next send. *)
  let produce () =
    match stream.keep_alive with
    | None -> stream.produce send
    | Some { Response.quiet; filler } ->
        let rec fill () =
          let left = nanoseconds quiet - (now_ns () - !last_sent) in
          if left > 0 then (
            Eio.Time.Mono.sleep_span clock
              (Mtime.Span.of_uint64_ns (Int64.of_int left));
            fill ())
          else
            match send filler with
            | Ok () -> fill ()
            | Error Response.Gone -> Eio.Fiber.await_cancel ()
        in
        Eio.Fiber.first (fun () -> stream.produce send) fill
  in
  match
    Fun.protect
      ~finally:(fun () ->
        produced := true;
        Request_repr.mark_client_gone req)
      produce
  with
  | Ok () | Error Response.Gone -> (
      match !failure with
      | Some Stalled ->
          log_end "client stopped reading";
          raise Stalled
      | Some Overran ->
          log_end "finished";
          log_length_mismatch ();
          false
      | Some _ ->
          log_end "client gone";
          false
      | None -> (
          log_end "finished";
          match framing with
          | Counted _ when !bytes_left > 0 ->
              log_length_mismatch ();
              false
          | Counted _ -> true
          (* Ends with the connection, so nothing may follow. *)
          | Raw -> (
              try
                Eio.Buf_write.string out.buf (gzip_trailer ());
                flush ~limits ~deadline out;
                false
              with
              | (Eio.Cancel.Cancelled _ | Stalled) as ex -> raise ex
              | _ -> false)
          | Chunked -> (
              try
                Write.chunk out.buf (gzip_trailer ());
                Write.last_chunk out.buf;
                flush ~limits ~deadline out;
                true
              with
              | (Eio.Cancel.Cancelled _ | Stalled) as ex -> raise ex
              | _ -> false)))
  | exception (Eio.Cancel.Cancelled _ as ex) ->
      log_end "connection closed";
      raise ex
  | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      L.err (fun m ->
          m "stream on %s failed: raised %s" (Request.path req)
            (Printexc.exn_slot_name ex)
            ~tags:
              (Log.tags
                 (("url.path", `String (Request.path req)) :: Log.raised ex bt)));
      false

(* Nothing after a head that could not be read can be trusted to be where it
   seems, so the connection closes. *)
let refuse_head ~read_clock ~limits ~deadline out status detail =
  L.info (fun m ->
      m "refused a request head: %d %s" (Status.to_int status) detail);
  let date =
    if Status.to_int status < 500 then
      [ ("date", Spindle_http.Date.to_string (read_clock ())) ]
    else []
  in
  write_head out.buf status
    (("content-length", "0") :: ("connection", "close") :: date);
  flush ~limits ~deadline out

(* ------------------------------------------------------------------ *)
(* The request's body *)

(* The time a byte buys: a second for every [min_body_rate]. *)
let per_byte ~min_body_rate =
  Mtime.Span.of_uint64_ns
    (Int64.div 1_000_000_000L (Int64.of_int min_body_rate))

(* Armed only while the body is read, so the handler's own time is never the
   client's: an allowance, and a second more for every [min_body_rate] bytes,
   so a byte sent just inside each wait cannot hold a connection open.
   Already buffered bytes count as arrived. *)
let within_body_deadline ~body_timeout ~min_body_rate ~deadline ic f =
  let per_byte = per_byte ~min_body_rate in
  let arrived = Eio.Buf_read.buffered_bytes ic in
  Deadline.arm deadline ~per_byte
    (Mtime.Span.add body_timeout Mtime.Span.(arrived * per_byte));
  Fun.protect ~finally:(fun () -> Deadline.clear deadline) f

type body_progress = {
  mutable cleared_to_send : bool;
      (** sent [100 Continue], or never asked for it; a request refused before
          its body is read never is (RFC 9110 §10.1.1) *)
  mutable reserved : int;  (** bytes of the body budget held *)
  mutable over_budget : bool;
}

(* A compare-and-set: two domains may each find room that is there for one. *)
let rec reserve_budget ~limits ~state progress n =
  let before = state.body_bytes_reserved in
  if before + n > limits.body_budget then false
  else if
    Atomic.Loc.compare_and_set [%atomic.loc state.body_bytes_reserved] before
      (before + n)
  then (
    progress.reserved <- progress.reserved + n;
    true)
  else reserve_budget ~limits ~state progress n

let release_budget ~state progress n =
  ignore
    (Atomic.Loc.fetch_and_add [%atomic.loc state.body_bytes_reserved] (-n)
      : int);
  progress.reserved <- progress.reserved - n

let request_body ~limits ~state ~deadline ~framing ~reader ~req ic out progress
    =
  (* A [100 Continue] the client cannot be sent is a body that will never
     come: a value for the route, as any body that stops arriving is. *)
  let continue_if_asked ~max =
    let too_large =
      match framing with
      | Framing.Fixed n -> n > max
      | Framing.No_body | Framing.Chunked | Framing.Until_close -> false
    in
    if progress.cleared_to_send || too_large then Ok ()
    else (
      Write.continue out.buf;
      match flush ~limits ~deadline out with
      | () ->
          progress.cleared_to_send <- true;
          Ok ()
      | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
      | exception Stalled ->
          Error (Body.Unreadable "the client stopped reading")
      | exception _ ->
          Request_repr.mark_client_gone req;
          Error (Body.Unreadable "the client has gone"))
  in
  let failed = function
    | `Too_large -> Error Body.Too_large
    | `Over_budget ->
        progress.over_budget <- true;
        Error Body.Over_budget
    | `Unreadable _ when Deadline.passed deadline ->
        Error (Body.Unreadable "the body stopped arriving")
    | `Unreadable detail -> Error (Body.Unreadable detail)
  in
  (* The route's limit where it gave one, the server's where it did not. *)
  let route_or ours = function Some limit -> limit | None -> ours in
  (* A client waiting for 100 Continue is refused while it still holds a
     body the budget has no room for. Room is checked, not taken: a length is
     only a claim until its bytes come. A whole body is held, so one the
     budget could never hold is the route's bug, whatever was sent. *)
  let whole ?max_body ?body_timeout ?min_body_rate () =
    let max_body = route_or limits.max_body max_body in
    if max_body > limits.body_budget then
      raise
        (Body_repr.Unholdable { max_body; body_budget = limits.body_budget });
    let no_room =
      match framing with
      | Framing.Fixed n ->
          (not progress.cleared_to_send)
          && n <= max_body
          && state.body_bytes_reserved + n > limits.body_budget
      | Framing.No_body | Framing.Chunked | Framing.Until_close -> false
    in
    if no_room then failed `Over_budget
    else
      match continue_if_asked ~max:max_body with
      | Error e -> Error e
      | Ok () -> (
          match
            within_body_deadline
              ~body_timeout:(route_or limits.body_timeout body_timeout)
              ~min_body_rate:(route_or limits.min_body_rate min_body_rate)
              ~deadline ic (fun () ->
                Framing.read reader ~max:max_body
                  ~reserve:(reserve_budget ~limits ~state progress))
          with
          | Ok s -> Ok s
          | Error e -> failed e)
  in
  (* One allowance for the whole body, spent only while a read waits. A part
     holds the budget until the next read; what the route keeps after that
     is its own. *)
  let allowance_left = ref None and part_reserved = ref 0 in
  (* A fiber the handler left behind may still be waiting in a read when
     it returns: [stop_reading] stops it, and the loop reads on only once it
     has let go of the connection. *)
  let returned, handler_returned = Eio.Promise.create () in
  let reading = ref None in
  let stop_reading () =
    Eio.Promise.resolve handler_returned ();
    Option.iter
      (fun unwound -> Eio.Cancel.protect (fun () -> Eio.Promise.await unwound))
      !reading
  in
  let part ?max_body ?body_timeout ?min_body_rate () =
    let max = route_or limits.max_body max_body in
    release_budget ~state progress !part_reserved;
    part_reserved := 0;
    match continue_if_asked ~max with
    | Error e -> Error e
    | Ok () -> (
        let per_byte =
          per_byte ~min_body_rate:(route_or limits.min_body_rate min_body_rate)
        in
        let allowance =
          match !allowance_left with
          | Some left -> left
          | None ->
              Mtime.Span.add
                (route_or limits.body_timeout body_timeout)
                Mtime.Span.(Eio.Buf_read.buffered_bytes ic * per_byte)
        in
        Deadline.arm deadline ~per_byte allowance;
        let unwound, unwind = Eio.Promise.create () in
        reading := Some unwound;
        let read =
          Fun.protect
            ~finally:(fun () ->
              allowance_left :=
                Some
                  (Option.value
                     (Deadline.remaining deadline)
                     ~default:Mtime.Span.zero);
              Deadline.clear deadline;
              reading := None;
              Eio.Promise.resolve unwind ())
            (fun () ->
              Eio.Fiber.first
                (fun () ->
                  Framing.read_some reader ~max ~reserve:(fun n ->
                      reserve_budget ~limits ~state progress n
                      && begin
                        part_reserved := n;
                        true
                      end))
                (fun () ->
                  Eio.Promise.await returned;
                  L.warn (fun m ->
                      m
                        "%s was still reading its body when its handler \
                         returned, which read nothing"
                        (Request.path req));
                  Ok `End))
        in
        match read with Ok part -> Ok part | Error e -> failed e)
  in
  ({ Body.whole; part }, stop_reading)

(* ------------------------------------------------------------------ *)
(* One exchange *)

(* The server decides: close whenever it will close, a stopping server
   included, and keep-alive only to an HTTP/1.0 client it keeps (RFC 9112
   §9.3). An answer that sends Upgrade -- a 426 -- names it as an option
   too (RFC 9110 §7.8). A takeover's is the upgrade its 101 names. *)
let connection_headers ~keep ~is_http_1_0 (wire : Wire.t) =
  match wire.body with
  | Wire.Connection _ -> wire.headers
  | Wire.Nothing | Wire.Bytes _ | Wire.Chunks _ | Wire.Counted _
  | Wire.Until_close _ -> (
      let upgrade =
        if Option.is_some (Field.find wire.headers "upgrade") then [ "upgrade" ]
        else []
      in
      let lasting =
        if not keep then [ "close" ]
        else if is_http_1_0 then [ "keep-alive" ]
        else []
      in
      match upgrade @ lasting with
      | [] -> wire.headers
      | options -> wire.headers @ [ ("connection", String.concat ", " options) ]
      )

(* Answers whether the connection may carry another request. *)
let exchange ~clock ~read_clock ~limits ~trace ~instruments ~state ~deadline app
    ic out peer head =
  match Framing.of_request head with
  | Error (status, detail) ->
      refuse_head ~read_clock ~limits ~deadline out status detail;
      false
  | Ok framing ->
      let reader =
        Framing.reader framing ic ~max_trailer:limits.max_header_bytes
      in
      let is_http_1_0 =
        match head.Head.Request.version with
        | Head.Http_1_0 -> true
        | Head.Http_1_1 -> false
      in
      (* An HTTP/1.0 client is never sent a 1xx (RFC 9110 §15.2), and a
         request without a body has nothing to be told to send. *)
      let has_body =
        match framing with
        | Framing.Fixed _ | Framing.Chunked -> true
        | Framing.No_body | Framing.Until_close -> false
      in
      let expects_continue =
        (not is_http_1_0) && has_body
        && Field.has_element head.headers "expect" "100-continue"
      in
      let progress =
        {
          cleared_to_send = not expects_continue;
          reserved = 0;
          over_budget = false;
        }
      in
      let req = make_request ~read_clock ~limits ~peer head in
      let handler_clock = Handler_clock.create clock in
      let body, stop_reading =
        request_body ~limits ~state ~deadline ~framing ~reader ~req ic out
          progress
      in
      (* A wait on the body is the body's limits', not the handler's. *)
      let body =
        {
          Body.whole =
            (fun ?max_body ?body_timeout ?min_body_rate () ->
              Handler_clock.reading handler_clock (fun () ->
                  body.whole ?max_body ?body_timeout ?min_body_rate ()));
          part =
            (fun ?max_body ?body_timeout ?min_body_rate () ->
              Handler_clock.reading handler_clock (fun () ->
                  body.part ?max_body ?body_timeout ?min_body_rate ()));
        }
      in
      let within handler_timeout handler =
        let limit =
          Option.value handler_timeout ~default:limits.handler_timeout
        in
        Result.map_error
          (fun () -> limit)
          (Handler_clock.within handler_clock ~limit handler)
      in
      let traceparent =
        match Field.all (Request.headers req) "traceparent" with
        | [ v ] -> Some v
        | _ -> None
      in
      (* A list a proxy may split across lines (W3C Trace Context §3.3.1.1),
         read only beside a traceparent. *)
      let tracestate =
        match traceparent with
        | None -> None
        | Some _ -> (
            match Field.all (Request.headers req) "tracestate" with
            | [] -> None
            | vs -> Some (String.concat "," vs))
      in
      (* Whatever the route handed [Request.client_gone] is told the
         exchange is over, however it ended. *)
      Fun.protect ~finally:(fun () -> Request_repr.mark_client_gone req)
      @@ fun () ->
      Log.with_request_id ?traceparent ?tracestate ?trace (Request.id req)
      @@ fun () ->
      let send_body (body, gzip, keep) =
        match body with
        | Wire.Nothing | Wire.Bytes _ -> keep
        | Wire.Chunks produce ->
            write_stream ?gzip ~clock ~limits ~deadline ~framing:Chunked req out
              produce
            && keep
        | Wire.Counted (n, produce) ->
            write_stream ~clock ~limits ~deadline ~framing:(Counted n) req out
              produce
            && keep
        | Wire.Until_close produce ->
            ignore
              (write_stream ?gzip ~clock ~limits ~deadline ~framing:Raw req out
                 produce
                : bool);
            false
        | Wire.Connection handle ->
            handle
              {
                Response.reader = ic;
                writer = take_over ~deadline out;
                clock :> Eio.Time.Mono.ty Eio.Resource.t;
                send_timeout = limits.send_timeout;
                stopping = state.stop_begun;
              };
            false
      in
      let answer () =
        Option.iter (fun i -> Metrics.add i.active [] 1) instruments;
        Fun.protect
          ~finally:(fun () ->
            Option.iter (fun i -> Metrics.add i.active [] (-1)) instruments;
            release_budget ~state progress progress.reserved)
          (fun () ->
            let started = Eio.Time.Mono.now clock in
            let response, answered = App.handle ~within app req ~body in
            stop_reading ();
            (* The body is the route's once it returns, so its budget is
               given back before the answer is written. *)
            release_budget ~state progress progress.reserved;
            let wire =
              Wire.render ?gzip:answered.gzip ?keys:(App.keys app) req response
            in
            log_access ~instruments req ~duration:(elapsed clock started)
              answered wire;
            (* What is left of the body is read before the answer is written,
               or a client still sending and a server still writing can wait on
               each other forever. A client that asked for 100 Continue and
               was never sent it may never send the body, so the connection
               closes. *)
            let body_finished =
              progress.cleared_to_send
              && within_body_deadline ~body_timeout:limits.body_timeout
                   ~min_body_rate:limits.min_body_rate ~deadline ic (fun () ->
                     Framing.discard reader ~limit:limits.discard_limit)
            in
            let can_continue =
              match wire.body with
              | Wire.Nothing | Wire.Bytes _ | Wire.Chunks _ | Wire.Counted _ ->
                  true
              | Wire.Until_close _ | Wire.Connection _ -> false
            in
            let keep =
              body_finished && can_continue
              && Head.Request.keep_alive head
              && (not state.stopping) && (not progress.over_budget)
              && not wire.closing
            in
            write_head out.buf wire.status
              (connection_headers ~keep ~is_http_1_0 wire);
            (match wire.body with
            | Wire.Bytes s -> Eio.Buf_write.string out.buf s
            | Wire.Nothing | Wire.Chunks _ | Wire.Counted _ | Wire.Until_close _
            | Wire.Connection _ ->
                ());
            flush ~limits ~deadline out;
            let answer = (wire.body, wire.gzip, keep) in
            (* A stream of known length ends by itself, within the send
               limit, so a drain waits for it as for a buffered answer. One of
               no length -- events -- ends only when [on_stop] tells its
               producer to, and leaves [in_flight] with its head. *)
            match wire.body with
            | Wire.Counted _ -> Either.Left (send_body answer)
            | Wire.Nothing | Wire.Bytes _ | Wire.Chunks _ | Wire.Until_close _
            | Wire.Connection _ ->
                Either.Right answer)
      in
      (* A takeover is in flight while it lasts, from its route on with no
         moment out between, so a drain that begins as its 101 goes still
         gives it time to say goodbye. It is no request being answered. *)
      let sent =
        while_in_flight state @@ fun () ->
        match answer () with
        | Either.Right ((Wire.Connection _, _, _) as taken_over) ->
            Either.Left (send_body taken_over)
        | (Either.Left _ | Either.Right _) as sent -> sent
      in
      Either.fold ~left:Fun.id ~right:send_body sent

(* The idle limit runs until the head's first byte, the head limit from
   there. A passed deadline reads as the end of input, so the deadline is
   what tells a slow head from a client that left. *)
let read_next_head ~limits ~deadline ic =
  Deadline.arm deadline limits.idle_timeout;
  match Eio.Buf_read.ensure ic 1 with
  | exception End_of_file -> `Gone
  | () -> (
      Deadline.arm deadline limits.head_timeout;
      let head = Head.Request.read ~max:limits.max_header_bytes ic in
      Deadline.clear deadline;
      match head with
      | Ok head -> `Request head
      | Error _ when Deadline.passed deadline ->
          `Refuse (`Request_timeout, "the head took too long")
      | Error Head.Closed -> `Gone
      | Error (Head.Refused (status, detail)) -> `Refuse (status, detail))

(* One page: what a socket is read and written in before a buffer grows,
   and more than most heads need. *)
let io_buffer_bytes = 4096

(* The connection's own output rather than [Buf_write.with_flow], which
   flushes before letting an exception out: to a client that stopped
   reading, a wait with no end. Here a raise aborts the buffer, and what is
   left once [f] returns has [send_timeout] from the last byte the client
   took, as any answer has. A write the socket refuses is raised to the
   flush that met it, which a stream's [send] answers as the client gone,
   so a handler learns it at its next send instead of being cancelled
   mid-transaction; a cancellation is raised as itself, never as the write
   error before it. *)
let with_output ~limits ~deadline flow f =
  Eio.Switch.run @@ fun sw ->
  let out =
    {
      buf = Eio.Buf_write.create ~sw io_buffer_bytes;
      flow :> Eio.Flow.sink_ty Eio.Resource.t;
      sw;
      copied = None;
      write_error = None;
    }
  in
  match f out with
  | v -> (
      Eio.Buf_write.close out.buf;
      match out.copied with
      | None ->
          (* Once a write was refused nothing more can go. *)
          if Option.is_none out.write_error then flush ~limits ~deadline out;
          v
      | Some copied -> (
          Deadline.arm_since_last deadline limits.send_timeout;
          match Deadline.wait deadline (fun () -> Eio.Promise.await copied) with
          | Some () -> v
          | None -> raise Stalled))
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex -> raise (Option.value out.write_error ~default:ex)

(* RFC 9112 §9.6: shut the write side, read and drop what still arrives for
   a while, then close. Closing with unread bytes has the kernel answer with
   a reset, which can overtake the answer -- a 413 above all, sent while the
   body is still arriving. The while is the connection's deadline, as every
   other wait on the client is. *)
let close_lingering ~limits ~deadline flow =
  match Eio.Flow.shutdown flow `Send with
  | exception Eio.Io _ -> ()
  | () ->
      let buf = Cstruct.create io_buffer_bytes in
      let rec drop left =
        if left > 0 then
          match Eio.Flow.single_read flow buf with
          | n -> drop (left - n)
          | exception (End_of_file | Eio.Io _) -> ()
      in
      Deadline.arm deadline limits.linger;
      ignore
        (Deadline.wait deadline (fun () -> drop limits.discard_limit)
          : unit option);
      Deadline.clear deadline

let serve_connection ~clock ~read_clock ~limits ~trace ~instruments ~state
    ~sweep app flow addr =
  let peer = peer_of_address addr in
  Deadline.run sweep @@ fun deadline ->
  let ic =
    Eio.Buf_read.of_flow
      (Deadline.reading deadline flow)
      ~initial_size:(min io_buffer_bytes limits.max_header_bytes)
      ~max_size:limits.max_header_bytes
  in
  (* Which side ends the connection: when it is the server, the client may
     still be sending. *)
  let rec loop out =
    match read_next_head ~limits ~deadline ic with
    | `Gone -> `Client_ended
    | `Refuse (status, detail) ->
        refuse_head ~read_clock ~limits ~deadline out status detail;
        `Server_ended
    | `Request head ->
        if
          exchange ~clock ~read_clock ~limits ~trace ~instruments ~state
            ~deadline app ic out peer head
        then loop out
        else `Server_ended
  in
  try
    match with_output ~limits ~deadline flow loop with
    | `Server_ended -> close_lingering ~limits ~deadline flow
    | `Client_ended -> ()
  with
  | Stalled ->
      L.info (fun m ->
          m "closed a connection whose client stopped reading for %a"
            Mtime.Span.pp limits.send_timeout)
  | Unwritable name ->
      L.err (fun m ->
          m "closed a connection on a head it could not write: %s" name)
  | Eio.Io (Eio.Net.E (Connection_reset _), _) -> ()
  | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (Unix.EPIPE, _, _)), _) -> ()

let wait_for_drain ~clock state ~drain =
  match
    Timeout.run (Timeout.v clock drain) (fun () ->
        Eio.Promise.await state.drained;
        Ok ())
  with
  | Ok () -> L.info (fun m -> m "stopped")
  | Error `Timeout ->
      L.warn (fun m ->
          m "stopped with %d requests unanswered after %a" state.in_flight
            Mtime.Span.pp drain)

(* Large enough to hold what a few hundred requests in flight keep alive, so
   they die young rather than being promoted: at OCaml's default of 256k
   words, 256 connections promoted a quarter of what each request allocated.
   8 MB a domain. *)
let minor_heap_words = 8 * 1024 * 1024 / (Sys.word_size / 8)

(* Per domain, since a new domain starts at the default; never lowered, so
   [OCAMLRUNPARAM]'s [s] can ask for more. *)
let raise_minor_heap () =
  let gc = Gc.get () in
  if gc.minor_heap_size < minor_heap_words then
    Gc.set { gc with minor_heap_size = minor_heap_words }

(* What [run] and [serve_on] are given, checked once for both: [run] checks
   before it binds, so a limit out of range is said before a port is held
   or [ready] says anything. *)
type settings = {
  limits : limits;
  domains : int option;
  max_connections : int;
  drain : Mtime.Span.t;
}

let settings ?domains ?(limits = Limits.default) ?(trusted_proxies = [])
    ?(proxy_header = Request.X_forwarded_for) () =
  Option.iter (check_count "domains" ~least:1) domains;
  let (l : Limits.t) = limits in
  {
    limits =
      {
        max_body = l.max_body;
        send_timeout = l.send_timeout;
        max_header_bytes = l.max_header_bytes;
        head_timeout = l.head_timeout;
        idle_timeout = l.idle_timeout;
        body_timeout = l.body_timeout;
        min_body_rate = l.min_body_rate;
        handler_timeout = l.handler_timeout;
        discard_limit = l.discard_limit;
        linger = l.linger;
        body_budget = l.body_budget;
        trusted_proxies = List.map proxy_of_string trusted_proxies;
        proxy_header;
      };
    domains;
    max_connections = l.max_connections;
    drain = l.drain;
  }

let serve settings ~mono_clock:clock ~read_clock ~domain_mgr ?stop
    ?(on_stop = ignore) ?trace ?metrics sockets app =
  let { limits; domains; max_connections; drain } = settings in
  let state =
    let drained, resolve_drained = Eio.Promise.create () in
    let stop_begun, resolve_stop_begun = Eio.Promise.create () in
    {
      in_flight = 0;
      stopping = false;
      body_bytes_reserved = 0;
      drained;
      resolve_drained;
      stop_begun;
      resolve_stop_begun;
    }
  in
  let instruments = Option.map (fun m -> make_instruments m state) metrics in
  (* A deadline passes up to a tick late, and a tick is a tenth of the
     shortest limit -- a linger of none is no wait -- so a tenth of a second
     at the defaults. *)
  let tick =
    let shortest =
      List.fold_left
        (fun a b -> if Mtime.Span.is_shorter b ~than:a then b else a)
        limits.head_timeout
        ([ limits.idle_timeout; limits.body_timeout; limits.send_timeout ]
        @
        if Mtime.Span.equal limits.linger Mtime.Span.zero then []
        else [ limits.linger ])
    in
    let tenth =
      Mtime.Span.of_uint64_ns
        (Int64.unsigned_div (Mtime.Span.to_uint64_ns shortest) 10L)
    in
    if Mtime.Span.is_shorter tenth ~than:Mtime.Span.ms then Mtime.Span.ms
    else tenth
  in
  let domains =
    match domains with
    | Some n -> n
    | None -> Domain.recommended_domain_count ()
  in
  (* Logged in the connection's own fiber rather than left to [accept_fork],
     which closes the socket first: another fiber's raise during that close
     would replace the backtrace. *)
  let log_connection_failure ex bt =
    (* An I/O error's words are the operating system's; any other raise,
       a takeover's handler's, is told by its kind. *)
    let why =
      match ex with
      | Eio.Io _ -> Printexc.to_string ex
      | _ -> "raised " ^ Printexc.exn_slot_name ex
    in
    L.warn (fun m ->
        m "connection failed: %s" why ~tags:(Log.tags (Log.raised ex bt)))
  in
  let on_error ex = log_connection_failure ex (Printexc.get_callstack 0) in
  (* Accepting stops only after [on_stop] has run, so nothing the
     application does to stop races a server that has let go of it. *)
  let accepting_stopped, stop_accepting = Eio.Promise.create () in
  (* One cap per address, shared by every domain, taken before [accept]. *)
  let sockets =
    List.map
      (fun socket -> (socket, Eio.Semaphore.make max_connections))
      sockets
  in
  (* An accept fails when the process is out of descriptors or the kernel
     out of memory, or when a connection was reset before it was taken. The
     socket stays readable through the first two, so accepting again at once
     would spin until they pass: a pause, short against any client's patience,
     lets connections close meanwhile. *)
  let accept_again_after = Mtime.Span.(10 * ms) in
  let accept ~sw ~sweep (socket, slots) =
    let rec loop () =
      Eio.Semaphore.acquire slots;
      match
        Eio.Net.accept_fork ~sw socket ~on_error (fun flow addr ->
            Option.iter (fun i -> Metrics.add i.connections [] 1) instruments;
            Fun.protect
              ~finally:(fun () ->
                Option.iter
                  (fun i -> Metrics.add i.connections [] (-1))
                  instruments;
                Eio.Semaphore.release slots)
              (fun () ->
                match
                  serve_connection ~clock ~read_clock ~limits ~trace
                    ~instruments ~state ~sweep app flow addr
                with
                | () -> ()
                | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
                | exception ex ->
                    let bt = Printexc.get_raw_backtrace () in
                    log_connection_failure
                      (Eio.Exn.add_context ex "handling connection from %a"
                         Eio.Net.Sockaddr.pp addr)
                      bt))
      with
      | () -> loop ()
      | exception (Eio.Io _ as ex) ->
          Eio.Semaphore.release slots;
          L.warn (fun m ->
              m "accept failed, accepting again in %a: %s" Mtime.Span.pp
                accept_again_after (Printexc.to_string ex));
          Eio.Time.Mono.sleep_span clock accept_again_after;
          loop ()
    in
    Eio.Fiber.first loop (fun () -> Eio.Promise.await accepting_stopped)
  in
  (* A domain's switch, its [Local.switch], holds its connections; its sweep
     is its own, since a sweep cancels waits only on its own domain. Eio's
     [run_server] has nowhere to put either. The sweep is a daemon, so it
     outlasts the accepting for connections still draining. *)
  let serve_domain () =
    raise_minor_heap ();
    Eio.Switch.run @@ fun sw ->
    Local.within ~sw @@ fun () ->
    let sweep = Deadline.sweep ~mono_clock:clock ~tick in
    Eio.Fiber.fork_daemon ~sw (fun () -> Deadline.watch sweep);
    Eio.Fiber.all (List.map (fun s () -> accept ~sw ~sweep s) sockets)
  in
  let serve_all_domains () =
    Eio.Fiber.all
      (serve_domain
      :: List.init (domains - 1) (fun _ () ->
          Eio.Domain_manager.run domain_mgr serve_domain))
  in
  match stop with
  | None -> serve_all_domains ()
  | Some stop ->
      (* The drain counts requests, not connections, which a proxy keeps idle
         indefinitely. What is left when it ends is cancelled. *)
      Eio.Fiber.first serve_all_domains (fun () ->
          Eio.Promise.await stop;
          state.stopping <- true;
          Eio.Promise.resolve state.resolve_stop_begun ();
          (* After [stopping] is set, the last request to end resolves
             [drained] itself. *)
          if state.in_flight = 0 then resolve_drained state;
          L.info (fun m ->
              m "stopping, with %d requests in flight" state.in_flight);
          on_stop ();
          Eio.Promise.resolve stop_accepting ();
          wait_for_drain ~clock state ~drain)

let serve_on ~mono_clock ~read_clock ~domain_mgr ?domains ?limits
    ?trusted_proxies ?proxy_header ?stop ?on_stop ?trace ?metrics sockets app =
  serve
    (settings ?domains ?limits ?trusted_proxies ?proxy_header ())
    ~mono_clock ~read_clock ~domain_mgr ?stop ?on_stop ?trace ?metrics sockets
    app

type listen_error = { host : string; port : int; failure : listen_failure }

and listen_failure =
  | In_use of string
  | Not_permitted of string
  | Not_local of string
  | Unknown_host
  | No_such_port
  | Failed of { address : string; reason : string }

let listen_error_to_string { host; port; failure } =
  let authority =
    if String.contains host ':' then Printf.sprintf "[%s]:%d" host port
    else Printf.sprintf "%s:%d" host port
  in
  let why =
    match failure with
    | In_use address ->
        Printf.sprintf "another program holds port %d on %s" port address
    | Not_permitted address ->
        Printf.sprintf
          "this program may not have port %d on %s, which below 1024 commonly \
           needs privileges"
          port address
    | Not_local address -> address ^ " is no address of this machine"
    | Unknown_host -> "the resolver knows no address for " ^ host
    | No_such_port -> "a port is 0 to 65535"
    | Failed { address; reason } ->
        Printf.sprintf "binding %s failed: %s" address reason
  in
  Printf.sprintf "cannot listen on %s: %s" authority why

let run ~sw ~net ~mono_clock:clock ~read_clock ~domain_mgr ?domains ~port
    ?(host = "localhost") ?(limits = Limits.default) ?trusted_proxies
    ?proxy_header ?stop ?on_stop ?(ready = ignore) ?trace ?metrics app =
  let settings = settings ?domains ~limits ?trusted_proxies ?proxy_header ()
  and backlog = limits.backlog in
  let address_to_string = Format.asprintf "%a" Eio.Net.Ipaddr.pp in
  let is_v6 = Eio.Net.Ipaddr.fold ~v4:(fun _ -> false) ~v6:(fun _ -> true) in
  (* Made here rather than by [Eio.Net.listen], which sets no option before
     it binds: an IPv6 socket takes IPv6 alone, since on most hosts it would
     take IPv4's port too, and another program holding that port could not
     then be told from it. *)
  let bind addr =
    let sockaddr = Eio_unix.Net.sockaddr_to_unix (`Tcp (addr, port)) in
    let domain = Unix.domain_of_sockaddr sockaddr in
    match Unix.socket ~cloexec:true domain Unix.SOCK_STREAM 0 with
    | exception Unix.Unix_error (code, _, _) -> Error code
    | fd -> (
        match
          Unix.setsockopt fd Unix.SO_REUSEADDR true;
          if is_v6 addr then Unix.setsockopt fd Unix.IPV6_ONLY true;
          Unix.bind fd sockaddr;
          Unix.listen fd backlog
        with
        | () ->
            Ok
              (Eio_unix.Net.import_socket_listening ~sw ~close_unix:true fd
                :> Eio_unix.Net.listening_socket_ty Eio.Resource.t)
        | exception Unix.Unix_error (code, _, _) ->
            Unix.close fd;
            Error code)
  in
  let failed_on addr code =
    let address = address_to_string addr in
    match code with
    | Unix.EADDRINUSE -> In_use address
    | Unix.EACCES | Unix.EPERM -> Not_permitted address
    | Unix.EADDRNOTAVAIL -> Not_local address
    | code -> Failed { address; reason = Unix.error_message code }
  in
  (* Every address or none. One marked optional is done without where the
     host has no IPv6 -- the family or the address unavailable -- and any
     other failure closes what was bound, so a server refused leaves nothing
     listening. *)
  let rec bind_all bound = function
    | [] -> Ok (List.rev bound)
    | (addr, optional) :: rest -> (
        match bind addr with
        | Ok socket -> bind_all ((addr, socket) :: bound) rest
        | Error (Unix.EAFNOSUPPORT | Unix.EADDRNOTAVAIL | Unix.EPROTONOSUPPORT)
          when optional ->
            bind_all bound rest
        | Error code ->
            List.iter (fun (_, socket) -> Eio.Resource.close socket) bound;
            Error (failed_on addr code))
  in
  let raw_bytes (a : Eio.Net.Ipaddr.v4v6) = (a :> string) in
  let is_wildcard a =
    String.equal (raw_bytes a) (raw_bytes Eio.Net.Ipaddr.V4.any)
    || String.equal (raw_bytes a) (raw_bytes Eio.Net.Ipaddr.V6.any)
  in
  let resolve_host () =
    match Eio.Net.getaddrinfo_stream net host with
    | exception Eio.Io (Eio.Net.E (Address_lookup_failed _), _) -> []
    | found ->
        List.fold_left
          (fun acc -> function
            | `Tcp (a, _)
              when not
                     (List.exists
                        (fun b -> String.equal (raw_bytes a) (raw_bytes b))
                        acc) ->
                a :: acc
            | `Tcp _ | `Unix _ -> acc)
          [] found
        |> List.rev
  in
  (* [localhost] is both loopback addresses whatever the resolver says: a
     browser asks for [::1] first, and a hosts file may name only one. It is
     a host's name, so in any case (RFC 4343). A wildcard is every interface
     of both families, since a container's port is forwarded over either. *)
  let wildcard, to_bind =
    if port < 0 || port > 65535 then (false, Error No_such_port)
    else if String.equal (String.lowercase_ascii host) "localhost" then
      ( false,
        Ok
          [
            (Eio.Net.Ipaddr.V4.loopback, false);
            (Eio.Net.Ipaddr.V6.loopback, true);
          ] )
    else
      match resolve_host () with
      | [] -> (false, Error Unknown_host)
      | addrs when List.exists is_wildcard addrs ->
          ( true,
            Ok [ (Eio.Net.Ipaddr.V6.any, true); (Eio.Net.Ipaddr.V4.any, false) ]
          )
      | addrs -> (false, Ok (List.map (fun a -> (a, false)) addrs))
  in
  match Result.bind to_bind (bind_all []) with
  | Error failure -> Error { host; port; failure }
  | Ok bound ->
      let addrs = List.map fst bound in
      let named =
        String.concat " and "
          (List.map
             (fun a ->
               if is_v6 a then "[" ^ address_to_string a ^ "]"
               else address_to_string a)
             addrs)
      in
      ready
        (if not wildcard then named
         else if List.exists is_v6 addrs then "every interface: " ^ named
         else "every interface: " ^ named ^ ", with no IPv6 here");
      serve settings ~mono_clock:clock ~read_clock ~domain_mgr ?stop ?on_stop
        ?trace ?metrics (List.map snd bound) app;
      Ok ()

let stop_on_signals ~sw () =
  let stopped, stop = Eio.Promise.create () in
  let signalled = Atomic.make false in
  let signal = Eio.Condition.create () in
  (* Broadcasting a condition is one of the few things Eio allows a signal
     handler. *)
  let on_signal (_ : int) =
    Atomic.set signalled true;
    Eio.Condition.broadcast signal
  in
  List.iter
    (fun s -> Sys.set_signal s (Sys.Signal_handle on_signal))
    [ Sys.sigterm; Sys.sigint ];
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Condition.loop_no_mutex signal (fun () ->
          if Atomic.get signalled then Some () else None);
      (* A second signal stops at once: Ctrl-C twice means now. *)
      List.iter
        (fun s -> Sys.set_signal s Sys.Signal_default)
        [ Sys.sigterm; Sys.sigint ];
      Eio.Promise.resolve stop ();
      `Stop_daemon);
  stopped

module Unix_socket = struct
  type failure =
    | In_use
    | Not_private of { directory : string; mode : int }
    | Too_long
    | Failed of string

  type error = { path : string; failure : failure }

  let error_to_string { path; failure } =
    Printf.sprintf "cannot listen on %s: %s" path
      (match failure with
      | In_use -> "a server answers there already"
      | Not_private { directory; mode } ->
          Printf.sprintf
            "%s is open to others (mode %o), and a socket in it would be too"
            directory mode
      | Too_long -> "the path is longer than the system takes for a socket"
      | Failed reason -> reason)

  (* Whether a server answers on the socket at [path]: one killed with its
     socket left the file, which nobody answers. *)
  let answered path =
    let fd = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        match Unix.connect fd (Unix.ADDR_UNIX path) with
        | () -> Ok true
        | exception Unix.Unix_error ((Unix.ECONNREFUSED | Unix.ENOENT), _, _) ->
            Ok false
        | exception Unix.Unix_error (code, _, _) -> Error code)

  (* The directory is checked rather than the file's mode trusted, since not
     every system honours a socket file's mode on connect; and it is what
     guards the instant between [bind] and [chmod]. *)
  let listen ~sw ?(backlog = 128) path =
    let refused failure = Error { path; failure } in
    let reason code = refused (Failed (Unix.error_message code)) in
    let directory = Filename.dirname path in
    match Unix.stat directory with
    | exception Unix.Unix_error (code, _, _) -> reason code
    | d when d.st_uid <> Unix.getuid () || d.st_perm land 0o077 <> 0 ->
        refused (Not_private { directory; mode = d.st_perm })
    | _ -> (
        let free =
          match Unix.lstat path with
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
          | exception Unix.Unix_error (Unix.ENAMETOOLONG, _, _) ->
              refused Too_long
          | exception Unix.Unix_error (code, _, _) -> reason code
          | f when f.st_kind <> Unix.S_SOCK ->
              refused (Failed "a file is there that is no socket")
          | _ -> (
              match answered path with
              | Ok true -> refused In_use
              | Ok false -> (
                  match Unix.unlink path with
                  | () -> Ok ()
                  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
                  | exception Unix.Unix_error (code, _, _) -> reason code)
              | Error Unix.ENAMETOOLONG -> refused Too_long
              | Error code -> reason code)
        in
        match free with
        | Error _ as e -> e
        | Ok () -> (
            let fd =
              Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0
            in
            match
              Unix.bind fd (Unix.ADDR_UNIX path);
              Unix.chmod path 0o600;
              Unix.listen fd backlog
            with
            | () ->
                Eio.Switch.on_release sw (fun () ->
                    try Unix.unlink path with Unix.Unix_error _ -> ());
                Ok
                  (Eio_unix.Net.import_socket_listening ~sw ~close_unix:true fd
                    :> [ `Generic ] Eio.Net.listening_socket_ty Eio.Resource.t)
            | exception Unix.Unix_error (code, _, _) -> (
                Unix.close fd;
                match code with
                | Unix.ENAMETOOLONG -> refused Too_long
                | Unix.EADDRINUSE -> refused In_use
                | code -> reason code)))
end
