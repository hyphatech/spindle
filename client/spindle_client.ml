(* Requests written and responses read by the same spindle_http code the
   server uses, so the framework has one account of where a message ends. *)

module Head = Spindle_http.Private.Head
module Framing = Spindle_http.Private.Framing
module Write = Spindle_http.Private.Write
module Field = Spindle_http.Field
module Status = Spindle_http.Status
module Trace = Spindle_http.Trace
module Websocket = Spindle_http.Websocket

let src = Logs.Src.create "spindle-client" ~doc:"Calls to other servers"

module L = (val Logs.src_log src : Logs.LOG)

(* What a TLS connection's reader reads through, noting whether its last
   read came back full. tls-eio decrypts all that has arrived, hands over as
   much as the buffer it is given holds, and keeps the rest where neither the
   socket nor the reader shows it; a read that came back short left nothing
   there, so only a full one can have. *)
module Filled = struct
  type t = {
    flow : Eio.Flow.source_ty Eio.Resource.t;
    mutable last_full : bool;
  }

  let read_methods = []

  let single_read t buf =
    let n = Eio.Flow.single_read t.flow buf in
    t.last_full <- n = Cstruct.length buf;
    n
end

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

(* A connection kept for the next call. [flow] is [socket] itself or TLS
   over it, and [tls_reads] what its reader reads through when it is TLS.
   [switch] is the connection's own, which its watch runs on, and resolving
   [release] ends it. Borrowing it resolves [stop_watch], which ends its
   watch without retiring it. *)
type connection = {
  socket : flow;
  switch : Eio.Switch.t;
  release : unit Eio.Promise.u;
  flow : flow;
  secure : bool;
  tls_reads : Filled.t option;
  reader : Eio.Buf_read.t;
  mutable stop_watch : unit Eio.Promise.u option;
}

(* eio_posix looks a name up in a system thread no cancellation reaches, so
   a call's deadline would wait for a slow resolver. One fiber on the
   client's switch takes lookups from any domain and runs each in a daemon
   of its own: a call abandons its wait at its deadline, and the lookup
   ends in the background. *)
module Resolver = struct
  type request = {
    host : string;
    port : int;
    answer : (Eio.Net.Sockaddr.stream list, exn) result Eio.Promise.u;
  }

  type t = request Eio.Stream.t

  let create ~sw net =
    let requests = Eio.Stream.create max_int in
    Eio.Fiber.fork_daemon ~sw (fun () ->
        let rec serve () =
          let { host; port; answer } = Eio.Stream.take requests in
          Eio.Fiber.fork_daemon ~sw (fun () ->
              Eio.Promise.resolve answer
                (match
                   Eio.Net.getaddrinfo_stream net host
                     ~service:(string_of_int port)
                 with
                | addresses -> Ok addresses
                | exception (Eio.Io _ as ex) -> Error ex);
              `Stop_daemon);
          serve ()
        in
        serve ());
    requests

  let lookup t host ~port =
    let answer, resolved = Eio.Promise.create () in
    Eio.Stream.add t { host; port; answer = resolved };
    Eio.Promise.await answer
end

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic ] Eio.Net.ty Eio.Resource.t;
  resolver : Resolver.t;
  tls : (Tls.Config.client, string) result;
      (** [Error] without a usable trust store; carried rather than raised, so
          {!create} is total and the failure arrives from {!call} like any other
      *)
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  timeout : Mtime.Span.t;
  max_body : int;
  per_host : int;
  idle_timeout : Mtime.Span.t;
  domain : Domain.id;  (** [sw]'s *)
  idle : (string, connection list) Hashtbl.t Domain.DLS.key;
      (** by scheme, host and port, one table per domain, so a call borrows only
          its own domain's and no lock is needed *)
}

type 'body response = {
  status : Status.t;
  headers : (string * string) list;
  body : 'body;
}

type error = [ `Unsent of string | `Lost of string ]

let error_to_string : [< error ] -> string = function `Unsent m | `Lost m -> m

(* Open where it is answered, so a caller's own failures join it under one
   [let*]; inside, a failure is exactly one of these. *)
let opened : ('a, error) result -> ('a, [> error ]) result = function
  | Ok v -> Ok v
  | Error (#error as e) -> Error e

(* Whether the request went out or not, a deadline that passed may have
   been after it did. *)
let timed_out span =
  `Lost (Format.asprintf "no answer within %a" Mtime.Span.pp span)

(* Four times what the server allows a request's head. *)
let max_head = 65_536

let tls ~authenticator =
  (* TLS needs a seeded generator and says so only at run time. Idempotent. *)
  Mirage_crypto_rng_unix.use_default ();
  match
    match authenticator with
    | Some a -> Ok a
    | None -> Ca_certs.authenticator ()
  with
  | Error (`Msg m) -> Error ("no usable certificate store: " ^ m)
  | Ok authenticator -> (
      match Tls.Config.client ~authenticator () with
      | Error (`Msg m) -> Error ("cannot configure TLS: " ^ m)
      | Ok config -> Ok config)

(* What failed before the request went out, so the server cannot have
   acted on it, and what failed after: a caller retries only the first. *)
exception Cannot_send of string
exception Failed of string

let cannot_send fmt = Printf.ksprintf (fun m -> raise (Cannot_send m)) fmt
let fail fmt = Printf.ksprintf (fun m -> raise (Failed m)) fmt

let create ~sw ~net ~mono_clock:clock ?(timeout = Mtime.Span.(30 * s))
    ?(max_body = 16_777_216) ?(per_host = 4)
    ?(idle_timeout = Mtime.Span.(15 * s)) ?authenticator () =
  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Resource.t) in
  {
    sw;
    net;
    resolver = Resolver.create ~sw net;
    tls = tls ~authenticator;
    clock :> Eio.Time.Mono.ty Eio.Resource.t;
    timeout;
    max_body;
    per_host;
    idle_timeout;
    domain = Domain.self ();
    idle = Domain.DLS.new_key (fun () -> Hashtbl.create 8);
  }

(* A connection is held by a daemon, so nothing idle holds the switch open;
   ending it closes what was kept. *)
let run ?timeout ?max_body ?per_host ?idle_timeout ?authenticator env f =
  Eio.Switch.run @@ fun sw ->
  f
    (create ~sw ~net:(Eio.Stdenv.net env)
       ~mono_clock:(Eio.Stdenv.mono_clock env)
       ?timeout ?max_body ?per_host ?idle_timeout ?authenticator ())

let idle_connections t = Domain.DLS.get t.idle

(* The domain's own switch where Spindle runs it, or the client's on the
   domain that made it. Elsewhere Eio cannot fork a watch, so a connection is
   closed after its call. *)
let local_switch t =
  match Spindle_http.Local.switch () with
  | Some sw -> Some sw
  | None when Int.equal (t.domain :> int) (Domain.self () :> int) -> Some t.sw
  | None -> None

(* The switch a call's connection lives on: its domain's, where it may be
   kept, or else one of the call's own, since it is closed after it. *)
let with_owner t f =
  match local_switch t with Some sw -> f sw | None -> Eio.Switch.run f

(* A request on a reused connection may be sent again if it never left, or,
   for an idempotent method, if no byte of an answer arrived. *)
exception Write_failed of string
exception Closed_unanswered

(* [authority] is without userinfo (RFC 9110 §7.2); [path] is the request
   target, its path and query. *)
type target = {
  https : bool;
  host : string;
  port : int;
  authority : string;
  path : string;
}

(* The path and query as the URL wrote them, since Uri decodes both and
   encodes them again its own way: [%3B] would go as [;], [+] as [%20], and
   a signed URL would no longer be the one signed. Where they begin and end
   is RFC 3986 Appendix B's -- after a scheme's [:] and an authority's
   [//], up to a [#] -- and an empty path is "/" (RFC 9112 §3.2.1). *)
let request_target url =
  let n = String.length url in
  let rec up_to i stops =
    if i < n && not (String.contains stops url.[i]) then up_to (i + 1) stops
    else i
  in
  let scheme_end = up_to 0 ":/?#" in
  let path =
    if scheme_end < n && Char.equal url.[scheme_end] ':' then scheme_end + 1
    else 0
  in
  let path =
    if
      path + 1 < n && Char.equal url.[path] '/' && Char.equal url.[path + 1] '/'
    then up_to (path + 2) "/?#"
    else path
  in
  match String.sub url path (up_to path "#" - path) with
  | "" -> "/"
  | target when Char.equal target.[0] '?' -> "/" ^ target
  | target -> target

let target_of ~url uri =
  let https =
    match Uri.scheme uri with
    | Some "https" -> true
    | Some "http" | None -> false
    | Some s -> cannot_send "a scheme this client does not speak: %s" s
  in
  let host =
    match Uri.host uri with
    | Some h when not (String.equal h "") -> h
    | Some _ | None -> cannot_send "a URL with no host"
  in
  let bracketed = if String.contains host ':' then "[" ^ host ^ "]" else host in
  let default = if https then 443 else 80 in
  {
    https;
    host;
    port = Option.value (Uri.port uri) ~default;
    authority =
      (match Uri.port uri with
      | Some p -> bracketed ^ ":" ^ string_of_int p
      | None -> bracketed);
    path = request_target url;
  }

let pool_key target =
  Printf.sprintf "%s://%s:%d"
    (if target.https then "https" else "http")
    target.host target.port

(* ------------------------------------------------------------------ *)
(* Connections, and the ones kept *)

(* TLS ends with its closure alert (RFC 9112 §9.8), so the server can tell an
   end from a truncation. Protected, so a cancelled call still closes; closed
   here rather than by its switch ending, so it is closed when this returns. *)
let close_connection c =
  Eio.Cancel.protect (fun () ->
      (if c.secure then try Eio.Flow.shutdown c.flow `All with Eio.Io _ -> ());
      (try Eio.Resource.close c.flow with Eio.Io _ -> ());
      ignore (Eio.Promise.try_resolve c.release () : bool))

(* The name or address a certificate is checked against; with neither it
   would be checked against nothing. Decided before a socket opens. *)
let tls_identity t target =
  if not target.https then None
  else
    match t.tls with
    | Error m -> cannot_send "%s" m
    | Ok config -> (
        match
          Result.bind (Domain_name.of_string target.host) Domain_name.host
        with
        | Ok host -> Some (config, `Host host)
        | Error _ -> (
            match Ipaddr.of_string target.host with
            | Ok ip -> Some (config, `Ip ip)
            | Error (`Msg _) ->
                cannot_send "a host that is neither a name nor an address: %s"
                  target.host))

(* A socket to [addr], on a switch of its own that a fiber on [sw] holds
   until the returned promise is resolved, or [sw] ends: [Eio.Net.connect]
   attaches a socket to its switch before connecting, so one that fails is
   closed as its attempt ends rather than kept until [sw] does -- a domain's
   switch, the server's lifetime. The fiber is a daemon, so nothing idle
   holds [sw] open. What fails once the socket is handed over is the
   fiber's, and fails [sw] as any fiber's does. *)
let connect_to ~sw net addr =
  Eio.Switch.check sw;
  let opened, open_ = Eio.Promise.create () in
  let released, release = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (match
         Eio.Switch.run (fun sw ->
             Eio.Fiber.first
               (fun () ->
                 let socket = Eio.Net.connect ~sw net addr in
                 Eio.Promise.resolve open_ (Ok ((socket :> flow), sw));
                 Eio.Fiber.await_cancel ())
               (fun () -> Eio.Promise.await released))
       with
      | () -> ()
      | exception ex -> (
          let bt = Printexc.get_raw_backtrace () in
          if not (Eio.Promise.try_resolve open_ (Error (ex, bt))) then
            Printexc.raise_with_backtrace ex bt;
          match ex with Eio.Cancel.Cancelled _ -> raise ex | _ -> ()));
      `Stop_daemon);
  match Eio.Promise.await opened with
  | Ok (socket, switch) -> (socket, switch, release)
  | Error (ex, bt) -> Printexc.raise_with_backtrace ex bt
  | exception (Eio.Cancel.Cancelled _ as ex) ->
      Eio.Promise.resolve release ();
      raise ex

(* Never on a caller's switch, since a kept connection outlives its call:
   [sw] is the call's owner ({!with_owner}), and a WebSocket's its bracket's,
   as it is never kept. Each address the resolver gives is tried in its
   order, the last failure being the call's: the first may be unreachable,
   an IPv6 one without a route (RFC 1123 §2.3). *)
let connect ~sw t target =
  let identity = tls_identity t target in
  let rec connect_first = function
    | [] -> cannot_send "no address for %s" target.host
    | [ addr ] -> connect_to ~sw t.net addr
    | addr :: rest -> (
        match connect_to ~sw t.net addr with
        | opened -> opened
        | exception (Eio.Io _ as ex) ->
            L.debug (fun m ->
                m "%a: %s" Eio.Net.Sockaddr.pp addr (Printexc.to_string ex));
            connect_first rest)
  in
  let socket, switch, release =
    match Resolver.lookup t.resolver target.host ~port:target.port with
    | Error ex -> cannot_send "%s" (Printexc.to_string ex)
    | Ok addresses -> (
        match connect_first addresses with
        | opened -> opened
        | exception (Eio.Io _ as ex) -> cannot_send "%s" (Printexc.to_string ex)
        )
  in
  let flow, secure =
    match identity with
    | None -> (socket, false)
    | Some (config, who) -> (
        let host, ip =
          match who with `Host h -> (Some h, None) | `Ip ip -> (None, Some ip)
        in
        match Tls_eio.client_of_flow config ?host ?ip socket with
        | tls -> ((tls :> flow), true)
        | exception ex -> (
            Eio.Cancel.protect (fun () ->
                (try Eio.Resource.close socket with Eio.Io _ -> ());
                Eio.Promise.resolve release ());
            match ex with
            | Eio.Io _ | End_of_file | Tls_eio.Tls_alert _
            | Tls_eio.Tls_failure _ ->
                cannot_send "%s" (Printexc.to_string ex)
            | _ -> raise ex))
  in
  let tls_reads : Filled.t option =
    if secure then
      Some { flow :> Eio.Flow.source_ty Eio.Resource.t; last_full = false }
    else None
  in
  let source =
    match tls_reads with
    | Some reads -> Eio.Resource.T (reads, Eio.Flow.Pi.source (module Filled))
    | None -> (flow :> Eio.Flow.source_ty Eio.Resource.t)
  in
  {
    socket;
    switch;
    release;
    flow;
    secure;
    tls_reads;
    reader = Eio.Buf_read.of_flow source ~max_size:max_head;
    stop_watch = None;
  }

let remove_idle t k c =
  let idle = idle_connections t in
  match Hashtbl.find_opt idle k with
  | Some kept -> (
      match List.filter (fun x -> x != c) kept with
      | [] -> Hashtbl.remove idle k
      | rest -> Hashtbl.replace idle k rest)
  | None -> ()

(* Returns once the server closes or sends anything. It only asks whether
   the socket is readable: a TLS flow keeps a cancelled read's exception and
   raises it at the next use. *)
let await_server_activity fd =
  Eio_unix.Fd.use fd Eio_unix.await_readable ~if_closed:Fun.id

(* Watched while idle (RFC 9112 §9.5): the server closing it or sending
   anything retires it, so one the server gave up on is never lent, and so
   does waiting past [idle_for]. The watch runs on the connection's own
   switch, so it ends before the socket closes with it, and is a daemon
   there. Kept only on a domain with a switch ({!with_owner}): elsewhere the
   connection's ends with its call. One with no descriptor to watch -- a mock
   network's -- is closed instead: nothing would tell the client the server
   had left it. *)
let keep_idle t k c ~idle_for =
  let idle = idle_connections t in
  let kept = Option.value (Hashtbl.find_opt idle k) ~default:[] in
  match (local_switch t, Eio_unix.Resource.fd_opt c.socket) with
  | None, _ | _, None -> close_connection c
  | Some _, Some _ when List.length kept >= t.per_host -> close_connection c
  | Some _, Some fd ->
      Hashtbl.replace idle k (c :: kept);
      let stopped, stop_watch = Eio.Promise.create () in
      c.stop_watch <- Some stop_watch;
      Eio.Fiber.fork_daemon ~sw:c.switch (fun () ->
          let retire =
            Eio.Fiber.first
              (fun () ->
                await_server_activity fd;
                true)
              (fun () ->
                Eio.Fiber.first
                  (fun () ->
                    Eio.Time.Mono.sleep_span t.clock idle_for;
                    true)
                  (fun () ->
                    Eio.Promise.await stopped;
                    false))
          in
          (* One borrowed in the same instant is borrowed. *)
          let waiting =
            List.exists
              (fun x -> x == c)
              (Option.value (Hashtbl.find_opt idle k) ~default:[])
          in
          if retire && waiting then (
            remove_idle t k c;
            close_connection c);
          `Stop_daemon)

(* Whether the server has said anything on a kept connection -- bytes, or
   its end -- asked now, without waiting: of the reader, of what TLS may be
   holding back, and of the socket. The watch learns it only once its fiber
   runs, and a call made before that would be sent on a connection the
   server had already left, or read what it said as the answer. poll(2)
   rather than select(2), which no descriptor past FD_SETSIZE can be given
   to. A connection with no descriptor is never kept, and would be one the
   server may have left. *)
let server_spoke c =
  Eio.Buf_read.buffered_bytes c.reader > 0
  || (match c.tls_reads with Some reads -> reads.last_full | None -> false)
  ||
  match Eio_unix.Resource.fd_opt c.socket with
  | None -> true
  | Some fd ->
      Eio_unix.Fd.use fd
        ~if_closed:(fun () -> true)
        (fun fd ->
          let poll = Iomux.Poll.create ~maxfds:1 () in
          Iomux.Poll.set_index poll 0 fd Iomux.Poll.Flags.pollin;
          Iomux.Poll.poll poll 1 Nowait > 0)

(* A kept connection the server has said nothing on since. *)
let rec borrow_idle t k =
  match Hashtbl.find_opt (idle_connections t) k with
  | Some (c :: _) ->
      remove_idle t k c;
      Option.iter (fun stop -> Eio.Promise.resolve stop ()) c.stop_watch;
      c.stop_watch <- None;
      if server_spoke c then (
        close_connection c;
        borrow_idle t k)
      else Some c
  | Some [] | None -> None

(* ------------------------------------------------------------------ *)
(* One exchange on one connection *)

(* RFC 9110 §8.6: a length for a body, and for a method that means one even
   when empty. *)
let length_header meth body =
  match (body, meth) with
  | Some b, _ -> [ ("Content-Length", string_of_int (String.length b)) ]
  | None, (`POST | `PUT | `PATCH) -> [ ("Content-Length", "0") ]
  | None, (`GET | `HEAD | `DELETE | `OPTIONS | `CONNECT | `TRACE | `Other _) ->
      []

(* RFC 9110 §9.2.2. *)
let is_idempotent = function
  | `GET | `HEAD | `PUT | `DELETE | `OPTIONS | `TRACE -> true
  | `POST | `PATCH | `CONNECT | `Other _ -> false

(* Passes the trace on: [tracestate] only beside its [traceparent], and
   neither where the caller wrote its own. *)
let send_request c meth target ~headers ~body =
  let headers =
    match Spindle_http.Log.traceparent () with
    | Some v when Option.is_none (Field.find headers "traceparent") -> (
        headers
        @ [ ("traceparent", v) ]
        @
        match Spindle_http.Log.tracestate () with
        | Some state when Option.is_none (Field.find headers "tracestate") ->
            [ ("tracestate", state) ]
        | Some _ | None -> [])
    | Some _ | None -> headers
  in
  let fields =
    (("Host", target.authority) :: headers) @ length_header meth body
  in
  match
    Eio.Buf_write.with_flow c.flow (fun oc ->
        (match Write.request_head oc meth ~target:target.path fields with
        | Ok () -> ()
        | Error (`Field name) ->
            cannot_send "a request field that cannot be written: %s" name
        | Error `Target -> cannot_send "a request target that cannot be written");
        Option.iter (Eio.Buf_write.string oc) body)
  with
  | () -> ()
  | exception (Eio.Io _ as ex) -> raise (Write_failed (Printexc.to_string ex))

(* Every 1xx before the final head is dropped (RFC 9110 §15.2), but a 101
   where the request asked to switch is the answer. Ending before a byte is
   [Closed_unanswered], after which a request may be sent again. *)
let rec read_final_head ?(switching = false) c ~first =
  match Head.Response.read ~max:max_head c.reader with
  | Error Head.Response.Closed when first -> raise Closed_unanswered
  | Error Head.Response.Closed ->
      fail "the server closed the connection mid-answer"
  | Error (Head.Response.Malformed m) ->
      fail "a response that could not be read: %s" m
  | Ok head when switching && Status.to_int head.status = 101 -> head
  | Ok head when Status.to_int head.status < 200 ->
      read_final_head ~switching c ~first:false
  | Ok head -> head

(* Keep-Alive's elements are [token [ "=" ( token / quoted-string ) ]], as
   Cache-Control's directives are, and its timeout delta-seconds, so it is
   read by that reader. A value it cannot read says no timeout. *)
let keep_alive_timeout headers =
  match Field.all headers "keep-alive" with
  | [] -> None
  | values -> (
      match Spindle_http.Cache_control.parse (String.concat ", " values) with
      | Ok elements ->
          Spindle_http.Cache_control.delta_seconds elements "timeout"
      | Error _ -> None)

(* [None] where either side said close or the body ended with the connection
   (RFC 9112 §9.3). A second short of the server's timeout, and not at all
   where that is a second or less: one lent as the server closes it would
   lose a POST, which is never sent twice. *)
let keep_idle_for t (head : Head.Response.t) framing ~caller_closes =
  match framing with
  | Framing.Until_close -> None
  | Framing.No_body | Framing.Fixed _ | Framing.Chunked -> (
      if caller_closes || not (Head.Response.keep_alive head) then None
      else
        match keep_alive_timeout head.headers with
        | Some seconds when seconds <= 1 -> None
        | Some seconds ->
            let before_server = Mtime.Span.((seconds - 1) * s) in
            Some
              (if Mtime.Span.is_shorter before_server ~than:t.idle_timeout then
                 before_server
               else t.idle_timeout)
        | None -> Some t.idle_timeout)

let receive_response t c meth ~caller_closes =
  let head = read_final_head c ~first:true in
  match Framing.of_response ~request_meth:meth head with
  | Error m -> fail "a response whose length cannot be told: %s" m
  | Ok framing -> (
      let reader = Framing.reader framing c.reader ~max_trailer:max_head in
      match Framing.read reader ~max:t.max_body ~reserve:(fun _ -> true) with
      | Ok body ->
          let kept = keep_idle_for t head framing ~caller_closes in
          ( {
              status = head.status;
              headers =
                List.map
                  (fun (k, v) -> (String.lowercase_ascii k, v))
                  head.headers;
              body;
            },
            kept )
      | Error `Too_large -> fail "a response longer than %d bytes" t.max_body
      | Error (`Unreadable m) -> fail "a response cut short: %s" m
      | Error `Over_budget -> fail "a response that could not be held")

(* ------------------------------------------------------------------ *)
(* A call *)

(* A caller's own beside one of these is a request a reader can take two
   ways. *)
let client_fields = [ "host"; "content-length"; "transfer-encoding" ]

(* A kept connection first; a request that met a reused connection's end is
   sent once more where that is safe (RFC 9112 §9.3.2). Kept only if the
   response allows, and closed on any raise. *)
let exchange ~sw t ~headers ~body meth target ~reused =
  (match
     List.find_opt
       (fun (n, _) -> List.mem (String.lowercase_ascii n) client_fields)
       headers
   with
  | Some (n, _) -> cannot_send "a request field the client writes itself: %s" n
  | None -> ());
  let k = pool_key target in
  let caller_closes = Field.has_element headers "connection" "close" in
  let rec attempt ~fresh =
    let c, was_kept =
      match if fresh then None else borrow_idle t k with
      | Some c -> (c, true)
      | None -> (connect ~sw t target, false)
    in
    reused := was_kept;
    match
      send_request c meth target ~headers ~body;
      receive_response t c meth ~caller_closes
    with
    | answer, Some idle_for ->
        keep_idle t k c ~idle_for;
        answer
    | answer, None ->
        close_connection c;
        answer
    | exception Write_failed _ when was_kept ->
        close_connection c;
        attempt ~fresh:true
    | exception Closed_unanswered when was_kept && is_idempotent meth ->
        close_connection c;
        attempt ~fresh:true
    | exception ex ->
        close_connection c;
        raise ex
  in
  attempt ~fresh:false

let error_of_exn = function
  | Cannot_send m -> Some (`Unsent m)
  | Write_failed m -> Some (`Unsent ("the request could not be written: " ^ m))
  | Failed m -> Some (`Lost m)
  | Closed_unanswered ->
      Some (`Lost "the server closed the connection without answering")
  | (Eio.Io _ | End_of_file | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _) as ex
    ->
      Some (`Lost (Printexc.to_string ex))
  | _ -> None

(* Named by method, as OpenTelemetry names a client span, [HTTP] for any
   other so a name is never a caller's string; described by where it went,
   never its query, which may carry a credential. A 4xx or 5xx fails it. *)
let within_client_span meth uri f =
  let name =
    match meth with
    | ( `GET | `HEAD | `POST | `PUT | `DELETE | `OPTIONS | `PATCH | `CONNECT
      | `TRACE ) as m ->
        Spindle_http.Meth.to_string m
    | `Other _ -> "HTTP"
  in
  Trace.within ~kind:Trace.Client
    ~attributes:
      ([
         ("http.request.method", `String (Spindle_http.Meth.to_string meth));
         ("server.address", `String (Option.value (Uri.host uri) ~default:""));
       ]
      @ (match Uri.port uri with
        | Some p -> [ ("server.port", `Int p) ]
        | None -> [])
      @ [
          ("url.scheme", `String (Option.value (Uri.scheme uri) ~default:""));
          ("url.path", `String (Uri.path uri));
        ])
    name
    (fun span ->
      let answered status =
        let status = Status.to_int status in
        Trace.add span [ ("http.response.status_code", `Int status) ];
        if status >= 400 then Trace.fail span (string_of_int status)
      and failed : error -> unit = function
        | `Unsent _ -> Trace.fail span "unsent"
        | `Lost _ -> Trace.fail span "lost"
      in
      f ~answered ~failed)

let call t ?timeout ?(headers = []) ?body meth url =
  let uri = Uri.of_string url in
  within_client_span meth uri @@ fun ~answered ~failed ->
  let deadline = Option.value timeout ~default:t.timeout in
  let started = Eio.Time.Mono.now t.clock in
  let reused = ref false in
  let result =
    match
      Eio.Time.Timeout.run (Eio.Time.Timeout.v t.clock deadline) (fun () ->
          with_owner t (fun sw ->
              Ok
                (exchange ~sw t ~headers ~body meth (target_of ~url uri) ~reused)))
    with
    | Ok answer -> Ok answer
    | Error `Timeout -> Error (timed_out deadline)
    | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
    | exception ex -> (
        match error_of_exn ex with Some e -> Error e | None -> raise ex)
  in
  L.debug (fun m ->
      m "%s %s: %s on a %s connection  (%a)"
        (Spindle_http.Meth.to_string meth)
        (Option.value (Uri.host uri) ~default:"?")
        (match result with
        | Ok r -> string_of_int (Status.to_int r.status)
        | Error e -> error_to_string e)
        (if !reused then "reused" else "new")
        Mtime.Span.pp
        (Mtime.span started (Eio.Time.Mono.now t.clock)));
  (match result with Ok r -> answered r.status | Error e -> failed e);
  opened result

(* ------------------------------------------------------------------ *)
(* An answer read as it arrives *)

module Body = struct
  type t = {
    reader : Framing.reader;
    clock : Eio.Time.Mono.ty Eio.Resource.t;
    wait : Mtime.Span.t;
    mutable state : state;
    mutable function_returned : bool;
  }

  (* A failed read is answered again: one cut off by its wait leaves a TLS
     connection unreadable, which would raise that cancellation at the next
     read, since a record half read cannot be resumed. *)
  and state = Reading | Ended | Failed of error

  (* Each wait bounded, never the whole: a stream's length is its own. After
     its function returns the connection is kept or closed, so a read reads
     nothing. *)
  let read b =
    let failed e =
      b.state <- Failed e;
      Error e
    in
    if b.function_returned then Ok `End
    else
      match b.state with
      | Ended -> Ok `End
      | Failed e -> Error e
      | Reading -> (
          match
            Eio.Time.Timeout.run (Eio.Time.Timeout.v b.clock b.wait) (fun () ->
                Ok
                  (Framing.read_some b.reader ~max:max_int ~reserve:(fun _ ->
                       true)))
          with
          | Error `Timeout -> failed (timed_out b.wait)
          | Ok (Ok (`Data s)) -> Ok (`Data s)
          | Ok (Ok `End) ->
              b.state <- Ended;
              Ok `End
          | Ok (Error (`Unreadable m)) ->
              failed (`Lost ("an answer cut short: " ^ m))
          | Ok (Error (`Too_large | `Over_budget)) ->
              failed (`Lost "an answer that could not be held")
          | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
          | exception ex -> (
              match error_of_exn ex with Some e -> failed e | None -> raise ex))

  let read b = opened (read b)
end

(* The connection and the answer's head, retried as a call is. *)
let open_answer ~sw t ~headers ~body meth target =
  (match
     List.find_opt
       (fun (n, _) -> List.mem (String.lowercase_ascii n) client_fields)
       headers
   with
  | Some (n, _) -> cannot_send "a request field the client writes itself: %s" n
  | None -> ());
  let k = pool_key target in
  let rec attempt ~fresh =
    let c, was_kept =
      match if fresh then None else borrow_idle t k with
      | Some c -> (c, true)
      | None -> (connect ~sw t target, false)
    in
    match
      send_request c meth target ~headers ~body;
      read_final_head c ~first:true
    with
    | head -> (c, head)
    | exception Write_failed _ when was_kept ->
        close_connection c;
        attempt ~fresh:true
    | exception Closed_unanswered when was_kept && is_idempotent meth ->
        close_connection c;
        attempt ~fresh:true
    | exception ex ->
        close_connection c;
        raise ex
  in
  attempt ~fresh:false

(* The span includes the reading: a stream's length is its cost. *)
let stream t ?timeout ?read_timeout ?(headers = []) ?body meth url f =
  let uri = Uri.of_string url in
  opened
  @@ within_client_span meth uri
  @@ fun ~answered ~failed ->
  let deadline = Option.value timeout ~default:t.timeout in
  let wait = Option.value read_timeout ~default:deadline in
  let caller_closes = Field.has_element headers "connection" "close" in
  with_owner t @@ fun sw ->
  (* Rather than [Timeout.run], which keeps the first of two fibers that
     finish in one step: an answer that arrived as the deadline passed
     would be dropped with its connection open. It is taken instead. *)
  let answer_if_any first second =
    match (first, second) with
    | (Ok _ as answer), _ | _, (Ok _ as answer) -> answer
    | Error `Timeout, Error `Timeout -> first
  in
  match
    Eio.Fiber.first ~combine:answer_if_any
      (fun () ->
        Eio.Time.Mono.sleep_span t.clock deadline;
        Error `Timeout)
      (fun () ->
        let target = target_of ~url uri in
        Ok (target, open_answer ~sw t ~headers ~body meth target))
  with
  | Error `Timeout ->
      let e = timed_out deadline in
      failed e;
      Error e
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex -> (
      match error_of_exn ex with
      | Some e ->
          failed e;
          Error e
      | None -> raise ex)
  | Ok (target, (c, head)) -> (
      answered head.status;
      match Framing.of_response ~request_meth:meth head with
      | Error m ->
          close_connection c;
          Error (`Lost ("a response whose length cannot be told: " ^ m))
      | Ok framing ->
          let b =
            {
              Body.reader =
                Framing.reader framing c.reader ~max_trailer:max_head;
              clock = t.clock;
              wait;
              state = Reading;
              function_returned = false;
            }
          in
          (* Kept only when read to the end and neither side said close: an
             unread body is the next answer's first bytes. *)
          let finally () =
            b.function_returned <- true;
            match (b.state, keep_idle_for t head framing ~caller_closes) with
            | Ended, Some idle_for -> keep_idle t (pool_key target) c ~idle_for
            | Ended, None | (Reading | Failed _), (Some _ | None) ->
                close_connection c
          in
          Ok
            (Fun.protect ~finally (fun () ->
                 f
                   {
                     status = head.status;
                     headers =
                       List.map
                         (fun (k, v) -> (String.lowercase_ascii k, v))
                         head.headers;
                     body = b;
                   })))

type events_end =
  | Finished of string option
  | Stopped of string option
  | Answered of string response

let is_event_stream headers =
  match
    Option.map Spindle_http.Media_type.parse (Field.find headers "content-type")
  with
  | Some (Ok { type_ = "text"; subtype = "event-stream"; _ }) -> true
  | Some (Ok _ | Error _) | None -> false

let events t ?timeout ?read_timeout ?(headers = []) ?last_event_id url on_event
    =
  let headers =
    [ ("Accept", "text/event-stream"); ("Cache-Control", "no-cache") ]
    @ (match last_event_id with
      | Some id -> [ ("Last-Event-ID", id) ]
      | None -> [])
    @ headers
  in
  Result.join
    (stream t ?timeout ?read_timeout ~headers `GET url (fun a ->
         if not (Status.equal a.status `OK && is_event_stream a.headers) then
           (* Not a stream: the answer, read whole as a call's is. *)
           let b = Buffer.create 256 in
           let rec whole () =
             match Body.read a.body with
             | Ok (`Data s) ->
                 Buffer.add_string b s;
                 if Buffer.length b > t.max_body then
                   Error
                     (`Lost
                        (Printf.sprintf "a response longer than %d bytes"
                           t.max_body))
                 else whole ()
             | Ok `End ->
                 Ok
                   (Answered
                      {
                        status = a.status;
                        headers = a.headers;
                        body = Buffer.contents b;
                      })
             | Error e -> Error e
           in
           whole ()
         else
           (* An event is bounded as an answer is. *)
           let r =
             Spindle_http.Event_stream.reader ?last_id:last_event_id
               ~max_event:t.max_body ()
           in
           let rec next () =
             match Body.read a.body with
             | Error e -> Error e
             | Ok `End -> Ok (Finished (Spindle_http.Event_stream.last_id r))
             | Ok (`Data s) -> (
                 let rec each = function
                   | [] -> next ()
                   | e :: rest -> (
                       match on_event e with
                       | `Continue -> each rest
                       | `Stop ->
                           Ok (Stopped (Spindle_http.Event_stream.last_id r)))
                 in
                 match Spindle_http.Event_stream.feed r s with
                 | Ok events -> each events
                 | Error m -> Error (`Lost m))
           in
           next ()))

(* ------------------------------------------------------------------ *)
(* A WebSocket *)

type websocket_error =
  [ error | `Not_upgraded of string response | Websocket.error ]

let websocket_error_to_string : [< websocket_error ] -> string = function
  | `Unsent m -> m
  | `Not_upgraded r ->
      Printf.sprintf "answered %d, which opens no socket"
        (Status.to_int r.status)
  | #Websocket.error as e -> Websocket.error_to_string e

(* A caller's own beside one of these would be a second answer. *)
let handshake_fields =
  [
    "upgrade";
    "connection";
    "sec-websocket-key";
    "sec-websocket-version";
    "sec-websocket-protocol";
    "sec-websocket-extensions";
  ]

let http_uri_of_ws uri =
  match Uri.scheme uri with
  | Some "ws" -> Uri.with_scheme uri (Some "http")
  | Some "wss" -> Uri.with_scheme uri (Some "https")
  | Some s -> cannot_send "a scheme a WebSocket is not opened over: %s" s
  | None -> cannot_send "a URL with no scheme"

(* RFC 6455 §4.1: a 101 that names websocket, answers this key, and speaks
   the protocol asked for, or none where none was. *)
let check_upgrade ~key protocol (head : Head.Response.t) =
  let fields = head.headers in
  let chosen = Field.find fields "sec-websocket-protocol" in
  if not (Field.has_element fields "upgrade" "websocket") then
    Error "a 101 that does not name websocket"
  else if not (Field.has_element fields "connection" "upgrade") then
    Error "a 101 without Connection: upgrade"
  else if
    not
      (Option.equal String.equal
         (Field.find fields "sec-websocket-accept")
         (Some (Spindle_http.Private.Websocket.accept_key key)))
  then Error "a 101 whose Sec-WebSocket-Accept is not for this key"
  else if Option.is_some (Field.find fields "sec-websocket-extensions") then
    Error "an extension this client never offered"
  else if
    not (Option.equal String.equal chosen (Websocket.subprotocol protocol))
  then Error "a 101 speaking another protocol than the one asked for"
  else Ok ()

(* Read whole, so the refusal's sentence reaches the caller; a body that
   cannot be read leaves the status to speak alone. *)
let refusal_body t c (head : Head.Response.t) =
  match Framing.of_response ~request_meth:`GET head with
  | Error _ -> ""
  | Ok framing -> (
      let reader = Framing.reader framing c.reader ~max_trailer:max_head in
      match Framing.read reader ~max:t.max_body ~reserve:(fun _ -> true) with
      | Ok body -> body
      | Error _ -> ""
      | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
      | exception _ -> "")

(* A socket's own writer rather than [Buf_write.with_flow], which waits for
   everything written to go: to a server that stopped reading, a wait with
   no end. What is left once [f] returns has [send_timeout] for the server
   to take anything, again after every byte it takes, and is then dropped
   with the connection. A write the socket refuses aborts the buffer, so the
   send waiting on it answers rather than raising. *)
let with_socket_writer t ~send_timeout c f =
  Eio.Switch.run @@ fun sw ->
  let writer = Eio.Buf_write.create ~sw 4096 in
  let taken = ref 0 in
  let copied, all_copied = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec copy () =
        match Eio.Buf_write.await_batch writer with
        | iovecs -> (
            match Eio.Flow.single_write c.flow iovecs with
            | n ->
                taken := !taken + n;
                Eio.Buf_write.shift writer n;
                copy ()
            | exception Eio.Io _ -> Eio.Buf_write.abort writer)
        | exception End_of_file -> ()
      in
      copy ();
      Eio.Promise.resolve all_copied ();
      `Stop_daemon);
  let v = f writer in
  Eio.Buf_write.close writer;
  let rec drain () =
    let before = !taken in
    match
      Eio.Time.Timeout.run (Eio.Time.Timeout.v t.clock send_timeout) (fun () ->
          Ok (Eio.Promise.await copied))
    with
    | Ok () -> ()
    | Error `Timeout -> if !taken > before then drain ()
  in
  drain ();
  v

let open_websocket t ?timeout ?(headers = []) ?keep_alive ?max_message protocol
    url f =
  let deadline = Option.value timeout ~default:t.timeout in
  let key = Base64.encode_string (Mirage_crypto_rng.generate 16) in
  Eio.Switch.run @@ fun sw ->
  let opened =
    match
      Eio.Time.Timeout.run (Eio.Time.Timeout.v t.clock deadline) (fun () ->
          (match
             List.find_opt
               (fun (n, _) ->
                 let n = String.lowercase_ascii n in
                 List.mem n client_fields || List.mem n handshake_fields)
               headers
           with
          | Some (n, _) ->
              cannot_send "a request field the client writes itself: %s" n
          | None -> ());
          let target = target_of ~url (http_uri_of_ws (Uri.of_string url)) in
          let c = connect ~sw t target in
          let handshake =
            [
              ("Upgrade", "websocket");
              ("Connection", "Upgrade");
              ("Sec-WebSocket-Key", key);
              ("Sec-WebSocket-Version", "13");
            ]
            @
            match Websocket.subprotocol protocol with
            | Some n -> [ ("Sec-WebSocket-Protocol", n) ]
            | None -> []
          in
          match
            send_request c `GET target ~headers:(headers @ handshake) ~body:None;
            read_final_head ~switching:true c ~first:true
          with
          | head when Status.to_int head.status <> 101 ->
              Fun.protect
                ~finally:(fun () -> close_connection c)
                (fun () -> Ok (`Refused (head, refusal_body t c head)))
          | head -> Ok (`Switching (c, head))
          | exception ex ->
              close_connection c;
              raise ex)
    with
    | Ok opened -> Ok opened
    | Error `Timeout -> Error (match timed_out deadline with #error as e -> e)
    | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
    | exception ex -> (
        match error_of_exn ex with
        | Some (#error as e) -> Error e
        | None -> raise ex)
  in
  match opened with
  | Error _ as e -> e
  | Ok (`Refused (head, body)) ->
      Error
        (`Not_upgraded
           {
             status = head.status;
             headers =
               List.map
                 (fun (k, v) -> (String.lowercase_ascii k, v))
                 head.headers;
             body;
           })
  | Ok (`Switching (c, head)) -> (
      match check_upgrade ~key protocol head with
      | Error m ->
          close_connection c;
          Error (`Lost m)
      | Ok () ->
          let ended =
            with_socket_writer t ~send_timeout:deadline c (fun writer ->
                Spindle_http.Private.Websocket.run_client ?keep_alive
                  ?max_message
                  ~mask:(fun () -> Mirage_crypto_rng.generate 4)
                  protocol
                  {
                    Spindle_http.Connection.reader = c.reader;
                    writer;
                    clock = t.clock;
                    send_timeout = deadline;
                    stopping = fst (Eio.Promise.create ());
                  }
                  f)
          in
          close_connection c;
          ended)

(* One line when it ends: a warning when it never opened or did not end
   cleanly, and an error, with what was raised, when its handler raised.
   Never the query, which may carry a credential. *)
let websocket t ?timeout ?headers ?keep_alive ?max_message protocol url f =
  let started = Eio.Time.Mono.now t.clock in
  let uri = Uri.of_string url in
  let host = Option.value (Uri.host uri) ~default:"?" in
  let log_end level ?(raised = []) how =
    L.msg level (fun m ->
        m "socket to %s%s ended: %s" host (Uri.path uri) how
          ~tags:
            (Spindle_http.Log.tags
               ([
                  ("server.address", `String host);
                  ("url.path", `String (Uri.path uri));
                  ( "duration",
                    `Int
                      (Int64.to_int
                         (Mtime.Span.to_uint64_ns
                            (Mtime.span started (Eio.Time.Mono.now t.clock))))
                  );
                  ("spindle.websocket.ended", `String how);
                ]
               @ raised)))
  in
  match
    open_websocket t ?timeout ?headers ?keep_alive ?max_message protocol url f
  with
  | Ok v ->
      log_end Logs.Info "closed";
      Ok v
  | Error e ->
      let level =
        match e with
        | `Socket (`Closed { Websocket.code = Normal | Going_away; _ }) ->
            Logs.Info
        | _ -> Logs.Warning
      in
      log_end level
        (match e with
        | #websocket_error as e -> websocket_error_to_string e
        | _ -> "its handler ended with a failure of its own");
      Error e
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      log_end Logs.Error
        ~raised:(Spindle_http.Log.raised ex bt)
        "its handler raised";
      Printexc.raise_with_backtrace ex bt

(* ------------------------------------------------------------------ *)
(* Spans, sent to a collector *)

module Otlp = struct
  module V = Wiretype.Value

  let batch_size = 512
  let queue_limit = 2048
  let send_interval = Mtime.Span.(5 * s)

  (* Filled from every domain, so behind a lock held only for a push or a
     take. [full] wakes the sender when a batch is waiting. *)
  type queue = {
    lock : Mutex.t;
    mutable spans : Trace.span list;  (** newest first *)
    mutable length : int;
    mutable dropped : int;
    full : Eio.Condition.t;
  }

  let push q span =
    let wake =
      Mutex.protect q.lock (fun () ->
          if q.length >= queue_limit then (
            q.dropped <- q.dropped + 1;
            false)
          else (
            q.spans <- span :: q.spans;
            q.length <- q.length + 1;
            q.length >= batch_size))
    in
    if wake then Eio.Condition.broadcast q.full

  let rec split_at n = function
    | x :: rest when n > 0 ->
        let first, later = split_at (n - 1) rest in
        (x :: first, later)
    | later -> ([], later)

  (* The oldest batch, and how many were dropped since the last take. *)
  let take_batch q =
    Mutex.protect q.lock (fun () ->
        let first, later = split_at batch_size (List.rev q.spans) in
        q.spans <- List.rev later;
        q.length <- List.length later;
        let dropped = q.dropped in
        q.dropped <- 0;
        (first, dropped))

  (* OTLP's JSON encoding: ids in hex, an instant and an integer as a
     decimal string, a kind and a status code as the protocol's numbers. *)
  let attribute_value : Trace.value -> V.t = function
    | `String s -> V.Object [ ("stringValue", V.String s) ]
    | `Int n -> V.Object [ ("intValue", V.String (string_of_int n)) ]
    | `Float f when Float.is_finite f ->
        V.Object [ ("doubleValue", V.Number f) ]
    | `Float f -> V.Object [ ("stringValue", V.String (Float.to_string f)) ]
    | `Bool b -> V.Object [ ("boolValue", V.Bool b) ]

  let attribute (k, v) =
    V.Object [ ("key", V.String k); ("value", attribute_value v) ]

  (* Nanoseconds since 1970, which 64 bits hold to the year 2262. *)
  let unix_nano t =
    let d, ps = Ptime.Span.to_d_ps (Ptime.to_span t) in
    Int64.to_string
      (Int64.add
         (Int64.mul (Int64.of_int d) 86_400_000_000_000L)
         (Int64.div ps 1_000L))

  let span (s : Trace.span) =
    V.Object
      ([ ("traceId", V.String s.trace_id); ("spanId", V.String s.span_id) ]
      @ (match s.parent_id with
        | Some p -> [ ("parentSpanId", V.String p) ]
        | None -> [])
      @ [
          ("name", V.String s.name);
          ( "kind",
            V.Number
              (match s.kind with
              | Trace.Internal -> 1.
              | Trace.Server -> 2.
              | Trace.Client -> 3.) );
          ("startTimeUnixNano", V.String (unix_nano s.start));
          ( "endTimeUnixNano",
            V.String (unix_nano (Spindle_http.Instant.add s.start s.duration))
          );
          ("attributes", V.Array (List.map attribute s.attributes));
          ( "status",
            V.Object
              (match s.status with
              | Trace.Unset -> []
              | Trace.Error how ->
                  [ ("code", V.Number 2.); ("message", V.String how) ]) );
        ])

  let document ~service spans =
    V.to_string
      (V.Object
         [
           ( "resourceSpans",
             V.Array
               [
                 V.Object
                   [
                     ( "resource",
                       V.Object
                         [
                           ( "attributes",
                             V.Array
                               [ attribute ("service.name", `String service) ]
                           );
                         ] );
                     ( "scopeSpans",
                       V.Array
                         [
                           V.Object
                             [
                               ( "scope",
                                 V.Object [ ("name", V.String "spindle") ] );
                               ("spans", V.Array (List.map span spans));
                             ];
                         ] );
                   ];
               ] );
         ])

  (* A batch per post. One the collector refuses is dropped and logged: a
     collector that is down would otherwise fill the queue. *)
  let rec send_waiting client q ~url ~headers ~service =
    match take_batch q with
    | [], 0 -> ()
    | spans, dropped ->
        if dropped > 0 then
          L.warn (fun m ->
              m "dropped %d spans: more ended than the collector was sent"
                dropped);
        (match spans with
        | [] -> ()
        | _ :: _ -> (
            match
              call client
                ~headers:(("Content-Type", "application/json") :: headers)
                ~body:(document ~service spans) `POST url
            with
            | Ok r when Status.to_int r.status / 100 = 2 -> ()
            | Ok r ->
                L.warn (fun m ->
                    m "the collector refused %d spans: %d" (List.length spans)
                      (Status.to_int r.status))
            | Error e ->
                L.warn (fun m ->
                    m "could not send %d spans to the collector: %s"
                      (List.length spans) (error_to_string e))));
        if List.length spans = batch_size then
          send_waiting client q ~url ~headers ~service

  let run ?ratio ?(headers = []) ~clock ~endpoint ~service client f =
    let url =
      (if String.ends_with ~suffix:"/" endpoint then
         String.sub endpoint 0 (String.length endpoint - 1)
       else endpoint)
      ^ "/v1/traces"
    in
    let q =
      {
        lock = Mutex.create ();
        spans = [];
        length = 0;
        dropped = 0;
        full = Eio.Condition.create ();
      }
    in
    let exporter =
      Trace.exporter ?ratio ~clock ~mono_clock:client.clock (push q)
    in
    (* One sender, so nothing is cancelled mid-post. Forked outside any
       request, so its own calls are in no trace and record no spans. *)
    let answer, answered = Eio.Promise.create () in
    let rec sender () =
      let finished =
        Eio.Fiber.any
          [
            (fun () ->
              Eio.Time.Mono.sleep_span client.clock send_interval;
              false);
            (fun () ->
              (* Asked again after each wake, and registered before it is
                 asked, so a batch that filled while a post was out, or on
                 another domain, is never missed. *)
              Eio.Condition.loop_no_mutex q.full (fun () ->
                  if Mutex.protect q.lock (fun () -> q.length >= batch_size)
                  then Some ()
                  else None);
              false);
            (fun () ->
              ignore (Eio.Promise.await answer);
              true);
          ]
      in
      send_waiting client q ~url ~headers ~service;
      if not finished then sender ()
    in
    Eio.Fiber.both (fun () -> Eio.Promise.resolve answered (f exporter)) sender;
    Eio.Promise.await answer
end

module Oauth = struct
  module Jwk = Spindle_http.Jwk
  module Value = Wiretype.Value
  module Urlencoded = Spindle_http.Urlencoded

  type keys = kid:string option -> Jwk.t list

  (* RFC 8414 §3.1 and OpenID Connect Discovery §4, in the order MCP's
     authorization tries them: the well-known names before the issuer's
     path, its terminating slash removed, then OpenID Connect's after it. *)
  let metadata_urls issuer =
    let u = Uri.of_string issuer in
    let path =
      let p = Uri.path u in
      if String.ends_with ~suffix:"/" p then String.sub p 0 (String.length p - 1)
      else p
    in
    let at p = Uri.to_string (Uri.with_path u p) in
    if String.equal path "" then
      [
        at "/.well-known/oauth-authorization-server";
        at "/.well-known/openid-configuration";
      ]
    else
      [
        at ("/.well-known/oauth-authorization-server" ^ path);
        at ("/.well-known/openid-configuration" ^ path);
        at (path ^ "/.well-known/openid-configuration");
      ]

  let ( let* ) = Result.bind

  let fetch client url =
    match call client `GET url with
    | Ok { status = `OK; body; _ } -> Ok body
    | Ok { status; _ } ->
        Error
          (Printf.sprintf "%s answered %d" url
             (Spindle_http.Status.to_int status))
    | Error e -> Error (error_to_string e)

  let member name = function
    | Value.Object members -> List.assoc_opt name members
    | _ -> None

  let string_member name v =
    match member name v with Some (Value.String s) -> Some s | _ -> None

  (* An authorization server's metadata, the first found where MCP looks for
     it, and used only where it names that issuer (RFC 8414 §3.3). *)
  let server_metadata client ~issuer =
    let rec first = function
      | [] -> Error "no metadata was found at any well-known URL"
      | url :: rest -> (
          match fetch client url with
          | Error _ -> first rest
          | Ok body -> (
              match Wiretype.decode Value.json body with
              | Error _ -> Error (url ^ " is no JSON")
              | Ok m -> (
                  match string_member "issuer" m with
                  | Some i when String.equal i issuer -> Ok m
                  | Some _ -> Error (url ^ " names another issuer")
                  | None -> Error (url ^ " names no issuer"))))
    in
    first (metadata_urls issuer)

  let jwks_uri client ~issuer =
    let* m = server_metadata client ~issuer in
    Option.to_result
      (string_member "jwks_uri" m)
      ~none:(issuer ^ "'s metadata names no jwks_uri")

  (* A token naming a key nobody has costs one fetch this often, however many
     arrive. *)
  let refetch_after = Mtime.Span.(1 * min)

  type kept = {
    mutable jwks_uri : string option;
    mutable keys : Jwk.t list;
    mutable fetched : Mtime.t option;
  }

  let keys client ~issuer =
    let lock = Eio.Mutex.create () in
    let kept = { jwks_uri = None; keys = []; fetched = None } in
    let refresh () =
      let now = Eio.Time.Mono.now client.clock in
      let fetched =
        let* uri =
          match kept.jwks_uri with
          | Some u -> Ok u
          | None ->
              let* u = jwks_uri client ~issuer in
              kept.jwks_uri <- Some u;
              Ok u
        in
        let* body = fetch client uri in
        Jwk.set_of_string body
      in
      kept.fetched <- Some now;
      match fetched with
      | Ok keys -> kept.keys <- keys
      | Error why ->
          L.warn (fun m -> m "the keys of %s were not fetched: %s" issuer why)
    in
    fun ~kid ->
      Eio.Mutex.use_rw ~protect:true lock (fun () ->
          let named k =
            match kid with
            | None -> true
            | Some id -> Option.equal String.equal (Jwk.kid k) (Some id)
          in
          let due =
            match kept.fetched with
            | None -> true
            | Some at ->
                Mtime.Span.compare
                  (Mtime.span at (Eio.Time.Mono.now client.clock))
                  refetch_after
                >= 0
          in
          if (not (List.exists named kept.keys)) && due then refresh ();
          List.filter named kept.keys)

  type registration = {
    issuer : string;
    client_id : string;
    secret : string option;
  }

  type tokens = {
    issuer : string;
    access : string;
    refresh : string option;
    expires : Ptime.t option;
    scopes : string list;
  }

  type store = {
    find : resource:string -> tokens option;
    keep : resource:string -> tokens -> unit;
  }

  let in_memory () =
    let kept = Atomic.make [] in
    {
      find = (fun ~resource -> List.assoc_opt resource (Atomic.get kept));
      keep =
        (fun ~resource tokens ->
          let rec put () =
            let old = Atomic.get kept in
            if
              not
                (Atomic.compare_and_set kept old
                   ((resource, tokens) :: List.remove_assoc resource old))
            then put ()
          in
          put ());
    }

  type oauth = {
    client : t;
    registered : registration list;
    metadata_document : string option;
    store : store;
    wait : Mtime.Span.t;
    now : unit -> Ptime.t;
    authorize : string -> unit;
  }

  (* The client's own, before this module's names them over. *)
  type calling = error

  let calling_to_string = error_to_string

  type nonrec error = [ error | `Oauth of string ]

  let error_to_string = function
    | #calling as e -> calling_to_string e
    | `Oauth why -> "signing in failed: " ^ why

  let is_https url =
    let u = Uri.of_string url in
    match (Uri.scheme u, Uri.host u) with
    | Some "https", Some h -> not (String.equal h "")
    | _ -> false

  (* A person given this long to sign in has walked away. *)
  let default_wait = Mtime.Span.(5 * min)

  let create ?(registered = []) ?metadata_document ?(store = in_memory ())
      ?(wait = default_wait) ~clock ~authorize client =
    (match metadata_document with
    | Some url
      when not
             (is_https url
             && not (String.equal (Uri.path (Uri.of_string url)) "")) ->
        invalid_arg
          (Printf.sprintf
             "Spindle_client.Oauth.create: %S is no https URL with a path" url)
    | _ -> ());
    {
      client;
      registered;
      metadata_document;
      store;
      wait;
      now = (fun () -> Spindle_http.Instant.of_clock clock);
      authorize;
    }

  let oauth_error why = Error (`Oauth why)
  let lift r = Result.map_error (fun why -> `Oauth why) r

  (* RFC 9728 §3.1, in the order MCP has a client try them: the resource's
     path after the well-known name, then the root. *)
  let resource_urls resource =
    let u = Uri.of_string resource in
    let at p = Uri.to_string (Uri.with_query (Uri.with_path u p) []) in
    let root = at "/.well-known/oauth-protected-resource" in
    let origin = Uri.to_string (Uri.with_query (Uri.with_path u "") []) in
    match Uri.path u with
    | "" | "/" -> [ (root, origin) ]
    | path ->
        let path =
          if String.ends_with ~suffix:"/" path then
            String.sub path 0 (String.length path - 1)
          else path
        in
        [
          (at ("/.well-known/oauth-protected-resource" ^ path), resource);
          (root, origin);
        ]

  (* The resource's metadata, used only where it names the resource it was
     found for (RFC 9728 §3.3): the URL a request went to where a challenge
     named it, else the identifier the well-known name was put in. *)
  let resource_metadata o ~resource ?metadata () =
    let candidates =
      match metadata with
      | Some url -> [ (url, resource) ]
      | None -> resource_urls resource
    in
    let rec first = function
      | [] -> oauth_error ("no metadata was found for " ^ resource)
      | (url, expected) :: rest -> (
          if not (is_https url) then oauth_error (url ^ " is no https URL")
          else
            match fetch o.client url with
            | Error _ -> first rest
            | Ok body -> (
                match Wiretype.decode Value.json body with
                | Error _ -> oauth_error (url ^ " is no JSON")
                | Ok m -> (
                    match string_member "resource" m with
                    | Some r when String.equal r expected -> Ok m
                    | Some _ -> oauth_error (url ^ " names another resource")
                    | None -> oauth_error (url ^ " names no resource"))))
    in
    first candidates

  let strings name m =
    match member name m with
    | Some (Value.Array l) ->
        List.filter_map (function Value.String s -> Some s | _ -> None) l
    | _ -> []

  let random_url_safe n =
    Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
      (Mirage_crypto_rng.generate n)

  (* 32 random octets: RFC 7636 §4.1's 43 characters, and as long a state. *)
  let entropy = 32

  let form_encoded s =
    let pair = Urlencoded.to_string [ ("x", s) ] in
    String.sub pair 2 (String.length pair - 2)

  (* Who this client is to that server, in MCP's order: an id registered with
     it, then a metadata document where it reads them. *)
  let identity o ~issuer m =
    match
      List.find_opt
        (fun (r : registration) -> String.equal r.issuer issuer)
        o.registered
    with
    | Some r -> Ok (r.client_id, r.secret)
    | None -> (
        match
          (o.metadata_document, member "client_id_metadata_document_supported" m)
        with
        | Some url, Some (Value.Bool true) -> Ok (url, None)
        | _ ->
            oauth_error
              (issuer
             ^ " has no id registered for this client, and reads no metadata \
                document"))

  let token_request o ~endpoint ~client_id ~secret form =
    let form =
      form
      @ match secret with None -> [ ("client_id", client_id) ] | Some _ -> []
    in
    let headers =
      [
        ("content-type", "application/x-www-form-urlencoded");
        ("accept", "application/json");
      ]
      @
      match secret with
      | Some secret ->
          (* RFC 6749 §2.3.1: each form-encoded, then joined. *)
          [
            ( "authorization",
              "Basic "
              ^ Base64.encode_string
                  (form_encoded client_id ^ ":" ^ form_encoded secret) );
          ]
      | None -> []
    in
    match
      call o.client ~headers ~body:(Urlencoded.to_string form) `POST endpoint
    with
    | Error e -> Error e
    | Ok answer -> (
        match Wiretype.decode Value.json answer.body with
        | Error _ -> oauth_error "the token endpoint answered no JSON"
        | Ok v -> (
            match (answer.status, string_member "access_token" v) with
            | `OK, Some access -> (
                match string_member "token_type" v with
                | Some t when String.equal (String.lowercase_ascii t) "bearer"
                  ->
                    Ok (access, v)
                | _ -> oauth_error "the token endpoint issued no bearer token")
            | _ ->
                oauth_error
                  ("the token endpoint refused: "
                  ^ Option.value (string_member "error" v) ~default:"no reason"
                  )))

  let tokens_of o ~issuer ~requested ~previous (access, v) =
    let now = o.now () in
    {
      issuer;
      access;
      refresh =
        (match string_member "refresh_token" v with
        | Some r -> Some r
        | None -> previous);
      expires =
        (match member "expires_in" v with
        | Some (Value.Number s) when s > 0. ->
            Some
              (Spindle_http.Instant.add now
                 (Mtime.Span.of_uint64_ns (Int64.of_float (s *. 1e9))))
        | _ -> None);
      scopes =
        (match string_member "scope" v with
        | Some s ->
            List.filter
              (fun x -> not (String.equal x ""))
              (String.split_on_char ' ' s)
        | None -> requested);
    }

  (* RFC 9207 §2.4, as MCP has it: a present iss is compared; an absent one
     is refused only where the server says it sends one. *)
  let issued_here ~issuer m params =
    match
      ( List.assoc_opt "iss" params,
        member "authorization_response_iss_parameter_supported" m )
    with
    | Some iss, _ when not (String.equal iss issuer) ->
        oauth_error "the answer names another issuer"
    | None, Some (Value.Bool true) -> oauth_error "the answer names no issuer"
    | _ -> Ok ()

  (* RFC 8252 §7.3: the browser is sent back to the loopback address, on a
     port the system gives, and the first answer there is the one. *)
  let callback o ~f =
    Eio.Switch.run @@ fun sw ->
    let socket =
      Eio.Net.listen o.client.net ~sw ~backlog:4 ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port =
      match Eio.Net.listening_addr socket with `Tcp (_, p) -> p | `Unix _ -> 0
    in
    let answered, answer = Eio.Promise.create () in
    let module Head = Spindle_http.Private.Head in
    let module Write = Spindle_http.Private.Write in
    Eio.Fiber.fork_daemon ~sw (fun () ->
        let rec accept () =
          if Eio.Promise.is_resolved answered then `Stop_daemon
          else (
            Eio.Switch.run (fun sw ->
                let flow, _ = Eio.Net.accept ~sw socket in
                let ic = Eio.Buf_read.of_flow flow ~max_size:65_536 in
                match Head.Request.read ~max:65_536 ic with
                | Error _ -> ()
                | Ok head ->
                    let u = Uri.of_string head.target in
                    let found = String.equal (Uri.path u) "/callback" in
                    if found && not (Eio.Promise.is_resolved answered) then
                      Eio.Promise.resolve answer
                        (Urlencoded.parse
                           (Option.value (Uri.verbatim_query u) ~default:""));
                    let body =
                      if found then "Signed in. You can close this window."
                      else "Not found."
                    in
                    Eio.Buf_write.with_flow flow (fun oc ->
                        match
                          Write.response_head oc
                            (if found then `OK else `Not_found)
                            [
                              ("content-type", "text/plain; charset=utf-8");
                              ( "content-length",
                                string_of_int (String.length body) );
                              ("connection", "close");
                            ]
                        with
                        | Ok () -> Eio.Buf_write.string oc body
                        | Error _ -> ()));
            accept ())
        in
        accept ());
    f
      ~redirect_uri:(Printf.sprintf "http://127.0.0.1:%d/callback" port)
      ~answered

  let sign_in o ~resource ?metadata ?scopes () =
    let* r = resource_metadata o ~resource ?metadata () in
    let resource =
      Option.value (string_member "resource" r) ~default:resource
    in
    let* issuer =
      match strings "authorization_servers" r with
      | [] -> oauth_error "the resource names no authorization server"
      | first :: _ as servers -> (
          match
            List.find_opt
              (fun s ->
                List.exists
                  (fun (g : registration) -> String.equal g.issuer s)
                  o.registered)
              servers
          with
          | Some s -> Ok s
          | None -> Ok first)
    in
    let* () =
      if is_https issuer then Ok ()
      else oauth_error (issuer ^ " is no https URL")
    in
    let* m = lift (server_metadata o.client ~issuer) in
    let* client_id, secret = identity o ~issuer m in
    let* authorization_endpoint =
      Option.to_result
        (string_member "authorization_endpoint" m)
        ~none:(`Oauth "the server names no authorization endpoint")
    in
    let* token_endpoint =
      Option.to_result
        (string_member "token_endpoint" m)
        ~none:(`Oauth "the server names no token endpoint")
    in
    (* RFC 7636 and MCP: a server that names no S256 is not signed in
       with, since its codes could be redeemed by whoever saw them. *)
    let* () =
      if
        List.exists (String.equal "S256")
          (strings "code_challenge_methods_supported" m)
      then Ok ()
      else oauth_error "the server names no S256 PKCE"
    in
    let scopes =
      match scopes with
      | None -> strings "scopes_supported" r
      | Some asked ->
          let kept =
            match o.store.find ~resource with
            | Some (t : tokens) -> t.scopes
            | None -> []
          in
          kept
          @ List.filter (fun s -> not (List.exists (String.equal s) kept)) asked
    in
    let verifier = random_url_safe entropy
    and state = random_url_safe entropy in
    let challenge =
      Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
        (Digestif.SHA256.to_raw_string (Digestif.SHA256.digest_string verifier))
    in
    callback o ~f:(fun ~redirect_uri ~answered ->
        let query =
          Urlencoded.to_string
            ([
               ("response_type", "code");
               ("client_id", client_id);
               ("redirect_uri", redirect_uri);
               ("code_challenge", challenge);
               ("code_challenge_method", "S256");
               ("state", state);
               ("resource", resource);
             ]
            @
            match scopes with
            | [] -> []
            | s -> [ ("scope", String.concat " " s) ])
        in
        let joined =
          match Uri.verbatim_query (Uri.of_string authorization_endpoint) with
          | Some _ -> authorization_endpoint ^ "&" ^ query
          | None -> authorization_endpoint ^ "?" ^ query
        in
        o.authorize joined;
        let* params =
          match
            Eio.Time.Timeout.run (Eio.Time.Timeout.v o.client.clock o.wait)
              (fun () -> Ok (Eio.Promise.await answered))
          with
          | Ok p -> Ok p
          | Error `Timeout -> oauth_error "nobody signed in in time"
        in
        (* RFC 9207 §2.4 before anything of the answer is believed, its error
           among them. *)
        let* () = issued_here ~issuer m params in
        let* () =
          match List.assoc_opt "state" params with
          | Some s when String.equal s state -> Ok ()
          | _ -> oauth_error "the answer is not this sign-in's"
        in
        let* code =
          match
            (List.assoc_opt "code" params, List.assoc_opt "error" params)
          with
          | Some c, _ -> Ok c
          | None, Some e -> oauth_error ("the server refused: " ^ e)
          | None, None -> oauth_error "the answer has no code"
        in
        let* issued =
          token_request o ~endpoint:token_endpoint ~client_id ~secret
            [
              ("grant_type", "authorization_code");
              ("code", code);
              ("redirect_uri", redirect_uri);
              ("code_verifier", verifier);
              ("resource", resource);
            ]
        in
        let tokens =
          tokens_of o ~issuer ~requested:scopes ~previous:None issued
        in
        o.store.keep ~resource tokens;
        Ok tokens)

  (* A token this close to its end is refreshed before it is sent. *)
  let refresh_within = Mtime.Span.(1 * min)

  let access o ~resource =
    match o.store.find ~resource with
    | None -> Ok None
    | Some (tokens : tokens) -> (
        let expiring =
          match tokens.expires with
          | None -> false
          | Some e ->
              Mtime.Span.compare
                (Spindle_http.Instant.until ~now:(o.now ()) e)
                refresh_within
              <= 0
        in
        match (expiring, tokens.refresh) with
        | false, _ -> Ok (Some tokens.access)
        | true, None -> Ok None
        | true, Some refresh -> (
            let refreshed =
              let* m = lift (server_metadata o.client ~issuer:tokens.issuer) in
              let* client_id, secret = identity o ~issuer:tokens.issuer m in
              let* token_endpoint =
                Option.to_result
                  (string_member "token_endpoint" m)
                  ~none:(`Oauth "the server names no token endpoint")
              in
              token_request o ~endpoint:token_endpoint ~client_id ~secret
                [
                  ("grant_type", "refresh_token");
                  ("refresh_token", refresh);
                  ("resource", resource);
                ]
            in
            match refreshed with
            | Ok issued ->
                let t =
                  tokens_of o ~issuer:tokens.issuer ~requested:tokens.scopes
                    ~previous:tokens.refresh issued
                in
                o.store.keep ~resource t;
                Ok (Some t.access)
            (* One that cannot be refreshed is signed in for again. *)
            | Error _ -> Ok None))
end
