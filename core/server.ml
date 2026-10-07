(* The connection loop reads and writes every byte itself: where a head and a
   body end, how an answer is framed, whether a connection carries another
   request, and how long anything may take. *)

module Local = Spindle_http.Local
module Status = Spindle_http.Status
module Meth = Spindle_http.Meth
module Head = Spindle_http.Head
module Framing = Spindle_http.Framing
module Field = Spindle_http.Field
module Write = Spindle_http.Write
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

(* A limit out of range is a constant written wrong where the server starts,
   refused there rather than read as a server that serves nobody or a
   deadline that is always passed. *)
let check_limit name ok shown =
  if not ok then
    invalid_arg (Printf.sprintf "Spindle.Server: ~%s cannot be %s" name shown)

let check_count name ~least n = check_limit name (n >= least) (string_of_int n)

let check_seconds name ~positive s =
  check_limit name
    (Float.is_finite s && if positive then s > 0. else s >= 0.)
    (Float.to_string s)

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

(* The rightmost address not a trusted proxy's: everything to its left was
   written by the client. *)
let forwarded_for ~trusted value =
  List.rev (Field.elements value)
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
  send_timeout_s : float;
  max_header_bytes : int;
  head_timeout_s : float;
  idle_timeout_s : float;
  body_timeout_s : float;
  min_body_rate : int;
  discard_limit : int;
  linger_s : float;
  body_budget : int;
  trusted_proxies : proxy list;
  proxy_header : Request.proxy_header;
}

(* Shared by every domain the server runs on. A stream leaves [in_flight] once
   its head has gone; [on_stop] is how its producer learns to end. *)
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

let make_request ~now ~limits ~peer (head : Head.Request.t) =
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
  Request.make ~id ~peer ~client ~proxied ~proxy_header:limits.proxy_header
    ~version:head.version ?host:head.host ~headers:head.headers ~now head.meth
    head.target

(* Nanoseconds, the unit collectors read a duration in, on the monotonic
   clock. *)
let elapsed_ns clock since =
  Int64.to_int
    (Mtime.Span.to_uint64_ns (Mtime.span since (Eio.Time.Mono.now clock)))

(* OpenTelemetry's method label: a method HTTP names, or [other] for any
   other, since every label value is a series kept for the process's life. *)
let meth_label ~other req =
  match Request.meth req with
  | (`GET | `HEAD | `POST | `PUT | `DELETE | `OPTIONS | `PATCH) as m ->
      Meth.to_string m
  | `Other _ -> other

(* From what goes out: the wire's status and refusal, and the bytes after the
   head. The path and never the query, which is where a callback carries a
   code. *)
let rec log_access ~instruments req ~ns (answered : App.answered)
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
      ("duration", `Int ns);
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
  L.msg answered.access (fun m ->
      m "%s %s %d"
        (Meth.to_string (Request.meth req))
        (Request.path req) status ~tags:(Log.tags fields));
  name_span req answered ~status (List.remove_assoc "duration" fields);
  Option.iter (record_duration req answered ~status ~ns) instruments

and record_duration req (answered : App.answered) ~status ~ns instruments =
  Metrics.observe instruments.duration
    [
      meth_label ~other:"_OTHER" req;
      Option.value answered.route ~default:"";
      string_of_int status;
    ]
    (float_of_int ns /. 1e9)

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

(* Bounded by progress, not by time: a client still reading a large answer
   slowly is not cut off. *)
let flush ~limits ~deadline oc =
  Deadline.arm_since_last deadline limits.send_timeout_s;
  let flushed = Deadline.wait deadline (fun () -> Eio.Buf_write.flush oc) in
  Deadline.clear deadline;
  match flushed with Some () -> () | None -> raise Stalled

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
let write_stream ?gzip ~clock ~limits ~deadline ~framing req oc
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
                 ("duration", `Int (elapsed_ns clock started));
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
          if is_chunked then Write.chunk oc s else Eio.Buf_write.string oc s;
          flush ~limits ~deadline oc
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
  (* The filler runs beside the producer and they take turns under a lock of
     this stream's own. A filler that cannot be written stops; the producer
     learns it at its next send. *)
  let produce () =
    match stream.keep_alive with
    | None -> stream.produce send
    | Some (quiet_s, filler) ->
        let lock = Eio.Mutex.create () and last_sent = ref started in
        let send s =
          Eio.Mutex.use_ro lock (fun () ->
              let sent = send s in
              last_sent := Eio.Time.Mono.now clock;
              sent)
        in
        let rec keep_alive () =
          let quiet =
            Mtime.Span.to_float_ns
              (Mtime.span !last_sent (Eio.Time.Mono.now clock))
            /. 1e9
          in
          if quiet < quiet_s then (
            Eio.Time.Mono.sleep clock (quiet_s -. quiet);
            keep_alive ())
          else
            match send filler with
            | Ok () -> keep_alive ()
            | Error Response.Gone -> Eio.Fiber.await_cancel ()
        in
        Eio.Fiber.first (fun () -> stream.produce send) keep_alive
  in
  match produce () with
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
                Eio.Buf_write.string oc (gzip_trailer ());
                flush ~limits ~deadline oc;
                false
              with
              | Eio.Cancel.Cancelled _ as ex -> raise ex
              | _ -> false)
          | Chunked -> (
              try
                Write.chunk oc (gzip_trailer ());
                Write.last_chunk oc;
                flush ~limits ~deadline oc;
                true
              with
              | Eio.Cancel.Cancelled _ as ex -> raise ex
              | _ -> false)))
  | exception (Eio.Cancel.Cancelled _ as ex) ->
      log_end "connection closed";
      raise ex
  | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      L.err (fun m ->
          m "stream on %s failed: %s" (Request.path req) (Printexc.to_string ex)
            ~tags:
              (Log.tags
                 (("url.path", `String (Request.path req)) :: Log.raised ex bt)));
      false

(* Nothing after a head that could not be read can be trusted to be where it
   seems, so the connection closes. *)
let refuse_head ~now ~limits ~deadline oc status detail =
  L.info (fun m ->
      m "refused a request head: %d %s" (Status.to_int status) detail);
  let date =
    if Status.to_int status < 500 then [ ("date", Write.date (now ())) ] else []
  in
  write_head oc status
    (("content-length", "0") :: ("connection", "close") :: date);
  flush ~limits ~deadline oc

(* ------------------------------------------------------------------ *)
(* The request's body *)

(* Armed only while the body is read, so the handler's own time is never the
   client's: an allowance, and a second more for every [min_body_rate] bytes,
   so a byte sent just inside each wait cannot hold a connection open.
   Already buffered bytes count as arrived. *)
let within_body_deadline ~limits ~deadline ic f =
  let per_byte = 1. /. float_of_int limits.min_body_rate in
  let arrived = float_of_int (Eio.Buf_read.buffered_bytes ic) in
  Deadline.arm deadline ~per_byte
    (limits.body_timeout_s +. (arrived *. per_byte));
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

let request_body ~limits ~state ~deadline ~framing ~reader ic oc progress =
  let continue_if_asked ~max =
    let too_large =
      match framing with
      | Framing.Fixed n -> n > max
      | Framing.No_body | Framing.Chunked | Framing.Until_close -> false
    in
    if progress.cleared_to_send || too_large then true
    else (
      Write.continue oc;
      match flush ~limits ~deadline oc with
      | () ->
          progress.cleared_to_send <- true;
          true
      | exception Stalled -> false)
  in
  let failed = function
    | `Too_large -> Error Body.Too_large
    | `Busy ->
        progress.over_budget <- true;
        Error Body.Busy
    | `Broken _ when Deadline.passed deadline ->
        Error (Body.Unreadable "the body stopped arriving")
    | `Broken detail -> Error (Body.Unreadable detail)
  in
  (* A client waiting for 100 Continue is refused while it still holds a
     body the budget has no room for. Room is checked, not taken: a length is
     only a claim until its bytes come. *)
  let whole () =
    let no_room =
      match framing with
      | Framing.Fixed n ->
          (not progress.cleared_to_send)
          && n <= limits.max_body
          && state.body_bytes_reserved + n > limits.body_budget
      | Framing.No_body | Framing.Chunked | Framing.Until_close -> false
    in
    if no_room then failed `Busy
    else if not (continue_if_asked ~max:limits.max_body) then
      Error (Body.Unreadable "the client stopped reading")
    else
      match
        within_body_deadline ~limits ~deadline ic (fun () ->
            Framing.read reader ~max:limits.max_body
              ~reserve:(reserve_budget ~limits ~state progress))
      with
      | Ok s -> Ok s
      | Error e -> failed e
  in
  (* One allowance for the whole body, spent only while a read waits. A part
     holds the budget until the next read; what the route keeps after that
     is its own. *)
  let allowance_left = ref None and part_reserved = ref 0 in
  let part ~max =
    release_budget ~state progress !part_reserved;
    part_reserved := 0;
    if not (continue_if_asked ~max) then
      Error (Body.Unreadable "the client stopped reading")
    else
      let per_byte = 1. /. float_of_int limits.min_body_rate in
      let allowance =
        match !allowance_left with
        | Some left -> left
        | None ->
            limits.body_timeout_s
            +. (float_of_int (Eio.Buf_read.buffered_bytes ic) *. per_byte)
      in
      Deadline.arm deadline ~per_byte allowance;
      let read =
        Fun.protect
          ~finally:(fun () ->
            allowance_left :=
              Some (Option.value (Deadline.remaining deadline) ~default:0.);
            Deadline.clear deadline)
          (fun () ->
            Framing.read_some reader ~max ~reserve:(fun n ->
                reserve_budget ~limits ~state progress n
                && begin
                  part_reserved := n;
                  true
                end))
      in
      match read with Ok part -> Ok part | Error e -> failed e
  in
  { Body.whole; part }

(* ------------------------------------------------------------------ *)
(* One exchange *)

(* The server decides: close whenever it will close, a stopping server
   included, and keep-alive only to an HTTP/1.0 client it keeps (RFC 9112
   §9.3). A takeover's is the upgrade its 101 names. *)
let connection_headers ~keep ~is_http_1_0 (wire : Wire.t) =
  match wire.body with
  | Wire.Connection _ -> wire.headers
  | Wire.Nothing | Wire.Bytes _ | Wire.Chunks _ | Wire.Counted _
  | Wire.Until_close _ ->
      if not keep then wire.headers @ [ ("connection", "close") ]
      else if is_http_1_0 then wire.headers @ [ ("connection", "keep-alive") ]
      else wire.headers

(* Answers whether the connection may carry another request. *)
let exchange ~clock ~now ~limits ~trace ~instruments ~state ~deadline app ic oc
    peer head =
  match Framing.of_request head with
  | Error (status, detail) ->
      refuse_head ~now ~limits ~deadline oc status detail;
      false
  | Ok framing -> (
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
        &&
        match Field.find head.headers "expect" with
        | Some v ->
            String.equal (String.lowercase_ascii (String.trim v)) "100-continue"
        | None -> false
      in
      let progress =
        {
          cleared_to_send = not expects_continue;
          reserved = 0;
          over_budget = false;
        }
      in
      let body =
        request_body ~limits ~state ~deadline ~framing ~reader ic oc progress
      in
      let req = make_request ~now ~limits ~peer head in
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
      Log.with_request_id ?traceparent ?tracestate ?trace (Request.id req)
      @@ fun () ->
      let wire_body, gzip, keep =
        while_in_flight state @@ fun () ->
        Option.iter (fun i -> Metrics.add i.active [] 1) instruments;
        Fun.protect
          ~finally:(fun () ->
            Option.iter (fun i -> Metrics.add i.active [] (-1)) instruments;
            release_budget ~state progress progress.reserved)
          (fun () ->
            let started = Eio.Time.Mono.now clock in
            let response, answered = App.handle app req ~body in
            (* The body is the route's once it returns, so its budget is
               given back before the answer is written. *)
            release_budget ~state progress progress.reserved;
            let wire = Wire.render ?gzip:answered.gzip req response in
            log_access ~instruments req ~ns:(elapsed_ns clock started) answered
              wire;
            (* What is left of the body is read before the answer is written,
               or a client still sending and a server still writing can wait on
               each other forever. A client that asked for 100 Continue and
               was never sent it may never send the body, so the connection
               closes. *)
            let body_finished =
              progress.cleared_to_send
              && within_body_deadline ~limits ~deadline ic (fun () ->
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
            write_head oc wire.status
              (connection_headers ~keep ~is_http_1_0 wire);
            (match wire.body with
            | Wire.Bytes s -> Eio.Buf_write.string oc s
            | Wire.Nothing | Wire.Chunks _ | Wire.Counted _ | Wire.Until_close _
            | Wire.Connection _ ->
                ());
            flush ~limits ~deadline oc;
            (wire.body, wire.gzip, keep))
      in
      match wire_body with
      | Wire.Nothing | Wire.Bytes _ -> keep
      | Wire.Chunks produce ->
          write_stream ?gzip ~clock ~limits ~deadline ~framing:Chunked req oc
            produce
          && keep
      | Wire.Counted (n, produce) ->
          write_stream ~clock ~limits ~deadline ~framing:(Counted n) req oc
            produce
          && keep
      | Wire.Until_close produce ->
          ignore
            (write_stream ?gzip ~clock ~limits ~deadline ~framing:Raw req oc
               produce
              : bool);
          false
      | Wire.Connection handle ->
          (* In flight while it lasts, so a drain gives it time to say
             goodbye. *)
          while_in_flight state (fun () ->
              handle
                {
                  Response.reader = ic;
                  writer = oc;
                  clock :> Eio.Time.Mono.ty Eio.Resource.t;
                  send_timeout_s = limits.send_timeout_s;
                  stopping = state.stop_begun;
                });
          false)

(* The idle limit runs until the head's first byte, the head limit from
   there. A passed deadline reads as the end of input, so the deadline is
   what tells a slow head from a client that left. *)
let read_next_head ~limits ~deadline ic =
  Deadline.arm deadline limits.idle_timeout_s;
  match Eio.Buf_read.ensure ic 1 with
  | exception End_of_file -> `Gone
  | () -> (
      Deadline.arm deadline limits.head_timeout_s;
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

(* The connection's own writer rather than [Buf_write.with_flow], which
   flushes before letting an exception out: to a client that stopped
   reading, a wait with no end. Here a raise cancels the copying fiber. A
   write the socket refuses aborts the buffer rather than raising, so a
   handler whose client left learns it at its next send instead of being
   cancelled mid-transaction; a cancellation is raised as itself, never as
   the write error before it. *)
let with_writer ~deadline flow f =
  Eio.Switch.run @@ fun sw ->
  let oc = Eio.Buf_write.create ~sw io_buffer_bytes in
  let write_error = ref None in
  Eio.Fiber.fork ~sw (fun () ->
      let rec copy () =
        match Eio.Buf_write.await_batch oc with
        | iovecs -> (
            match Eio.Flow.single_write flow iovecs with
            | n ->
                Deadline.progress deadline n;
                Eio.Buf_write.shift oc n;
                copy ()
            | exception (Eio.Io _ as ex) ->
                write_error := Some ex;
                Eio.Buf_write.abort oc)
        | exception End_of_file -> ()
      in
      copy ());
  match f oc with
  | v ->
      Eio.Buf_write.close oc;
      v
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex -> raise (Option.value !write_error ~default:ex)

(* RFC 9112 §9.6: shut the write side, read and drop what still arrives for
   a while, then close. Closing with unread bytes has the kernel answer with
   a reset, which can overtake the answer -- a 413 above all, sent while the
   body is still arriving. *)
let close_lingering ~clock ~limits flow =
  match Eio.Flow.shutdown flow `Send with
  | exception Eio.Io _ -> ()
  | () -> (
      let buf = Cstruct.create io_buffer_bytes in
      let rec drop left =
        if left > 0 then
          match Eio.Flow.single_read flow buf with
          | n -> drop (left - n)
          | exception (End_of_file | Eio.Io _) -> ()
      in
      match
        Timeout.run (Timeout.seconds clock limits.linger_s) (fun () ->
            Ok (drop limits.discard_limit))
      with
      | Ok () | Error `Timeout -> ())

let serve_connection ~clock ~now ~limits ~trace ~instruments ~state ~sweep app
    flow addr =
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
  let rec loop oc =
    match read_next_head ~limits ~deadline ic with
    | `Gone -> `Client_ended
    | `Refuse (status, detail) ->
        refuse_head ~now ~limits ~deadline oc status detail;
        `Server_ended
    | `Request head ->
        if
          exchange ~clock ~now ~limits ~trace ~instruments ~state ~deadline app
            ic oc peer head
        then loop oc
        else `Server_ended
  in
  try
    match with_writer ~deadline flow loop with
    | `Server_ended -> close_lingering ~clock ~limits flow
    | `Client_ended -> ()
  with
  | Stalled ->
      L.info (fun m ->
          m "closed a connection whose client stopped reading for %gs"
            limits.send_timeout_s)
  | Unwritable name ->
      L.err (fun m ->
          m "closed a connection on a head it could not write: %s" name)
  | Eio.Io (Eio.Net.E (Connection_reset _), _) -> ()
  | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (Unix.EPIPE, _, _)), _) -> ()

let wait_for_drain ~clock state ~drain_s =
  match
    Timeout.run (Timeout.seconds clock drain_s) (fun () ->
        Eio.Promise.await state.drained;
        Ok ())
  with
  | Ok () -> L.info (fun m -> m "stopped")
  | Error `Timeout ->
      L.warn (fun m ->
          m "stopped with %d requests unanswered after %gs" state.in_flight
            drain_s)

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

let serve_on ~mono_clock:clock ~now ~domain_mgr ?domains ?(max_body = 1_048_576)
    ?(max_header_bytes = 16_384) ?(head_timeout_s = 10.) ?(idle_timeout_s = 60.)
    ?(body_timeout_s = 20.) ?(min_body_rate = 500) ?(send_timeout_s = 30.)
    ?(discard_limit = 65_536) ?(linger_s = 1.) ?(body_budget = 67_108_864)
    ?(trusted_proxies = []) ?(proxy_header = Request.X_forwarded_for)
    ?(max_connections = 512) ?stop ?(drain_s = 10.) ?(on_stop = ignore) ?trace
    ?metrics sockets app =
  Option.iter (check_count "domains" ~least:1) domains;
  check_count "max_body" ~least:0 max_body;
  check_count "max_header_bytes" ~least:1 max_header_bytes;
  check_count "min_body_rate" ~least:1 min_body_rate;
  check_count "discard_limit" ~least:0 discard_limit;
  check_count "body_budget" ~least:0 body_budget;
  check_count "max_connections" ~least:1 max_connections;
  check_seconds "head_timeout_s" ~positive:true head_timeout_s;
  check_seconds "idle_timeout_s" ~positive:true idle_timeout_s;
  check_seconds "body_timeout_s" ~positive:true body_timeout_s;
  check_seconds "send_timeout_s" ~positive:true send_timeout_s;
  check_seconds "linger_s" ~positive:false linger_s;
  check_seconds "drain_s" ~positive:false drain_s;
  let limits =
    {
      max_body;
      send_timeout_s;
      max_header_bytes;
      head_timeout_s;
      idle_timeout_s;
      body_timeout_s;
      min_body_rate;
      discard_limit;
      linger_s;
      body_budget;
      trusted_proxies = List.map proxy_of_string trusted_proxies;
      proxy_header;
    }
  in
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
     shortest limit: once a second at the defaults. *)
  let tick =
    Float.max 0.001
      (List.fold_left Float.min head_timeout_s
         [ idle_timeout_s; body_timeout_s; send_timeout_s ]
      /. 10.)
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
    L.warn (fun m ->
        m "connection failed: %s" (Printexc.to_string ex)
          ~tags:(Log.tags (Log.raised ex bt)))
  in
  let on_error ex = log_connection_failure ex (Printexc.get_callstack 0) in
  (* Accepting stops only after [on_stop] has run, so nothing the
     application does to stop races a server that has let go of it. *)
  let accepting_stopped, stop_accepting = Eio.Promise.create () in
  (* One cap per address, shared by every domain, taken before [accept]: a
     cap under the descriptor limit keeps [accept] from failing with EMFILE,
     which Eio does not catch and which would cancel every connection. *)
  let sockets =
    List.map
      (fun socket -> (socket, Eio.Semaphore.make max_connections))
      sockets
  in
  let accept ~sw ~sweep (socket, slots) =
    let rec loop () =
      Eio.Semaphore.acquire slots;
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
                serve_connection ~clock ~now ~limits ~trace ~instruments ~state
                  ~sweep app flow addr
              with
              | () -> ()
              | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
              | exception ex ->
                  let bt = Printexc.get_raw_backtrace () in
                  log_connection_failure
                    (Eio.Exn.add_context ex "handling connection from %a"
                       Eio.Net.Sockaddr.pp addr)
                    bt));
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
          wait_for_drain ~clock state ~drain_s)

let run ~sw ~net ~mono_clock:clock ~now ~domain_mgr ?domains ~port
    ?(host = "localhost") ?max_body ?max_header_bytes ?head_timeout_s
    ?idle_timeout_s ?body_timeout_s ?min_body_rate ?send_timeout_s
    ?discard_limit ?linger_s ?body_budget ?trusted_proxies ?proxy_header
    ?(backlog = 128) ?max_connections ?stop ?drain_s ?on_stop ?(ready = ignore)
    ?trace ?metrics app =
  let bind addr =
    Eio.Net.listen net ~sw ~backlog ~reuse_addr:true (`Tcp (addr, port))
  in
  (* A host without IPv6 says so as the family or address being unavailable,
     or from the io_uring backend as any error of Eio's own. Reading all of
     those as a missing family is safe because the other family is bound
     unguarded, so a port in use still fails there. *)
  let bind_if_supported addr =
    match bind addr with
    | s -> Some s
    | exception
        ( Eio.Exn.Io _
        | Unix.Unix_error
            ( (Unix.EAFNOSUPPORT | Unix.EADDRNOTAVAIL | Unix.EPROTONOSUPPORT),
              _,
              _ ) ) ->
        None
  in
  let address_to_string = Format.asprintf "%a" Eio.Net.Ipaddr.pp in
  let raw_bytes (a : Eio.Net.Ipaddr.v4v6) = (a :> string) in
  let is_wildcard a =
    String.equal (raw_bytes a) (raw_bytes Eio.Net.Ipaddr.V4.any)
    || String.equal (raw_bytes a) (raw_bytes Eio.Net.Ipaddr.V6.any)
  in
  let resolve_host () =
    List.fold_left
      (fun acc -> function
        | `Tcp (a, _)
          when not
                 (List.exists
                    (fun b -> String.equal (raw_bytes a) (raw_bytes b))
                    acc) ->
            a :: acc
        | `Tcp _ | `Unix _ -> acc)
      []
      (Eio.Net.getaddrinfo_stream net host)
    |> List.rev
  in
  (* [localhost] is both loopback addresses whatever the resolver says: a
     browser asks for [::1] first, and a hosts file may name only one. A
     wildcard is every interface of both families, since a container's port
     is forwarded over either. *)
  let sockets, bound_to =
    if String.equal host "localhost" then
      let v4 = bind Eio.Net.Ipaddr.V4.loopback in
      match bind_if_supported Eio.Net.Ipaddr.V6.loopback with
      | Some v6 -> ([ v4; v6 ], "127.0.0.1 and [::1]")
      | None -> ([ v4 ], "127.0.0.1")
    else
      let addrs = resolve_host () in
      if List.exists is_wildcard addrs then
        match bind_if_supported Eio.Net.Ipaddr.V6.any with
        | None ->
            ( [ bind Eio.Net.Ipaddr.V4.any ],
              "every interface: 0.0.0.0, with no IPv6 here" )
        | Some v6 -> (
            (* On a dual-stack host the IPv6 wildcard takes IPv4 too, and
               binding IPv4 then fails as in use: raised from the socket call
               by the posix backend, as Eio's own error by io_uring's. *)
            let v6_only =
              ([ v6 ], "every interface: [::], which takes IPv4 too")
            in
            match bind Eio.Net.Ipaddr.V4.any with
            | v4 -> ([ v6; v4 ], "every interface: [::] and 0.0.0.0")
            | exception Unix.Unix_error (Unix.EADDRINUSE, _, _) -> v6_only
            | exception
                Eio.Io
                  (Eio.Exn.X (Eio_unix.Unix_error (Unix.EADDRINUSE, _, _)), _)
              ->
                v6_only)
      else
        ( List.map bind addrs,
          String.concat " and " (List.map address_to_string addrs) )
  in
  ready bound_to;
  serve_on ~mono_clock:clock ~now ~domain_mgr ?domains ?max_body
    ?max_header_bytes ?head_timeout_s ?idle_timeout_s ?body_timeout_s
    ?min_body_rate ?send_timeout_s ?discard_limit ?linger_s ?body_budget
    ?trusted_proxies ?proxy_header ?max_connections ?stop ?drain_s ?on_stop
    ?trace ?metrics sockets app

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
