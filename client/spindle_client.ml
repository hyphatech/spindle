(* Requests written and responses read by the same spindle_http code the
   server uses, so the framework has one account of where a message ends. *)

module Head = Spindle_http.Head
module Framing = Spindle_http.Framing
module Write = Spindle_http.Write
module Field = Spindle_http.Field
module Status = Spindle_http.Status
module Trace = Spindle_http.Trace
module Websocket = Spindle_http.Websocket

let src = Logs.Src.create "spindle.client" ~doc:"Calls to other servers"

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

(* A connection kept for the next call. [flow] is [socket] itself or TLS
   over it, and [tls_reads] what its reader reads through when it is TLS.
   Borrowing it resolves [stop_watch], which ends its watch without retiring
   it. *)
type connection = {
  socket : Eio_unix.Net.stream_socket_ty Eio.Resource.t;
  flow : [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t;
  secure : bool;
  tls_reads : Filled.t option;
  reader : Eio.Buf_read.t;
  mutable stop_watch : unit Eio.Promise.u option;
}

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic ] Eio.Net.ty Eio.Resource.t;
  tls : (Tls.Config.client, string) result;
      (** [Error] without a usable trust store; carried rather than raised, so
          {!create} is total and the failure arrives from {!call} like any other
      *)
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  timeout_s : float;
  max_body : int;
  per_host : int;
  idle_s : float;
  domain : Domain.id;  (** [sw]'s *)
  idle : (string, connection list) Hashtbl.t Domain.DLS.key;
      (** by scheme, host and port, one table per domain, so a call borrows only
          its own domain's and no lock is needed *)
}

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

type error = Unreachable of string | Timed_out of float

let error_to_string = function
  | Unreachable m -> m
  | Timed_out s -> Printf.sprintf "no answer within %.0fs" s

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

let create ~sw ~net ~mono_clock:clock ?(timeout_s = 30.)
    ?(max_body = 16_777_216) ?(per_host = 4) ?(idle_s = 15.) ?authenticator () =
  {
    sw;
    net :> [ `Generic ] Eio.Net.ty Eio.Resource.t;
    tls = tls ~authenticator;
    clock :> Eio.Time.Mono.ty Eio.Resource.t;
    timeout_s;
    max_body;
    per_host;
    idle_s;
    domain = Domain.self ();
    idle = Domain.DLS.new_key (fun () -> Hashtbl.create 8);
  }

(* Watches are daemons, so nothing idle holds the switch open; ending it
   closes what was kept. *)
let run ?timeout_s ?max_body ?per_host ?idle_s ?authenticator env f =
  Eio.Switch.run @@ fun sw ->
  f
    (create ~sw ~net:(Eio.Stdenv.net env)
       ~mono_clock:(Eio.Stdenv.mono_clock env)
       ?timeout_s ?max_body ?per_host ?idle_s ?authenticator ())

let idle_connections t = Domain.DLS.get t.idle

(* The domain's own switch where Spindle runs it, or the client's on the
   domain that made it. Elsewhere Eio cannot fork a watch, so a connection is
   closed after its call. *)
let local_switch t =
  match Spindle_http.Local.switch () with
  | Some sw -> Some sw
  | None when Int.equal (t.domain :> int) (Domain.self () :> int) -> Some t.sw
  | None -> None

exception Failed of string

(* A request on a reused connection may be sent again if it never left, or,
   for an idempotent method, if no byte of an answer arrived. *)
exception Unsent of string
exception Unanswered

let fail fmt = Printf.ksprintf (fun m -> raise (Failed m)) fmt

(* [authority] is without userinfo (RFC 9110 §7.2); an empty path is "/"
   (RFC 9112 §3.2.1). *)
type target = {
  https : bool;
  host : string;
  port : int;
  authority : string;
  path : string;
}

let target_of uri =
  let https =
    match Uri.scheme uri with
    | Some "https" -> true
    | Some "http" | None -> false
    | Some s -> fail "a scheme this client does not speak: %s" s
  in
  let host =
    match Uri.host uri with
    | Some h when not (String.equal h "") -> h
    | Some _ | None -> fail "a URL with no host"
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
    path = (match Uri.path_and_query uri with "" -> "/" | p -> p);
  }

let pool_key target =
  Printf.sprintf "%s://%s:%d"
    (if target.https then "https" else "http")
    target.host target.port

(* ------------------------------------------------------------------ *)
(* Connections, and the ones kept *)

(* TLS ends with its closure alert (RFC 9112 §9.8), so the server can tell an
   end from a truncation. Protected, so a cancelled call still closes. *)
let close_connection c =
  Eio.Cancel.protect (fun () ->
      (if c.secure then try Eio.Flow.shutdown c.flow `All with Eio.Io _ -> ());
      try Eio.Resource.close c.flow with Eio.Io _ -> ())

(* The name or address a certificate is checked against; with neither it
   would be checked against nothing. Decided before a socket opens. *)
let tls_identity t target =
  if not target.https then None
  else
    match t.tls with
    | Error m -> fail "%s" m
    | Ok config -> (
        match
          Result.bind (Domain_name.of_string target.host) Domain_name.host
        with
        | Ok host -> Some (config, `Host host)
        | Error _ -> (
            match Ipaddr.of_string target.host with
            | Ok ip -> Some (config, `Ip ip)
            | Error (`Msg _) ->
                fail "a host that is neither a name nor an address: %s"
                  target.host))

(* Rather than [Eio.Net.connect], which attaches a socket to the switch
   before connecting and keeps a failed one there until the switch ends: here
   that is the server's lifetime. The socket joins [sw] only connected; a
   failure is the [Eio.Io] [Net.connect] would raise. *)
let connect_socket ~sw addr =
  let unix_addr = Eio_unix.Net.sockaddr_to_unix addr in
  let as_eio = function
    | Unix.Unix_error (code, name, arg) -> Eio_unix.Err.v code name arg
    | ex -> ex
  in
  let connect fd =
    Unix.set_nonblock fd;
    match Unix.connect fd unix_addr with
    | () -> ()
    | exception
        Unix.Unix_error ((EINPROGRESS | EINTR | EAGAIN | EWOULDBLOCK), _, _)
      -> (
        Eio_unix.await_writable fd;
        match Unix.getsockopt_error fd with
        | None -> ()
        | Some code -> raise (Unix.Unix_error (code, "connect", "")))
  in
  match
    Unix.socket ~cloexec:true
      (Unix.domain_of_sockaddr unix_addr)
      Unix.SOCK_STREAM 0
  with
  | exception ex -> raise (as_eio ex)
  | fd -> (
      match connect fd with
      | () -> Eio_unix.Net.import_socket_stream ~sw ~close_unix:true fd
      | exception ex ->
          (try Unix.close fd with Unix.Unix_error _ -> ());
          raise (as_eio ex))

(* Never on a caller's switch, since a kept connection outlives its call. A
   WebSocket's is given its bracket's switch: it is never kept. *)
let connect ?sw t target =
  let identity = tls_identity t target in
  let sw =
    match sw with
    | Some sw -> sw
    | None -> Option.value (local_switch t) ~default:t.sw
  in
  (* Each address in turn, the last failure being the call's: the first may
     be unreachable, an IPv6 one without a route (RFC 1123 §2.3). *)
  let rec connect_first = function
    | [] -> fail "no address for %s" target.host
    | [ addr ] -> connect_socket ~sw addr
    | addr :: rest -> (
        match connect_socket ~sw addr with
        | socket -> socket
        | exception (Eio.Io _ as ex) ->
            L.debug (fun m ->
                m "%a: %s" Eio.Net.Sockaddr.pp addr (Printexc.to_string ex));
            connect_first rest)
  in
  let socket =
    connect_first
      (Eio.Net.getaddrinfo_stream t.net target.host
         ~service:(string_of_int target.port))
  in
  let flow, secure =
    match identity with
    | None ->
        ( (socket
            :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t),
          false )
    | Some (config, who) -> (
        let host, ip =
          match who with `Host h -> (Some h, None) | `Ip ip -> (None, Some ip)
        in
        match Tls_eio.client_of_flow config ?host ?ip socket with
        | tls ->
            ( (tls
                :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ]
                   Eio.Resource.t),
              true )
        | exception ex ->
            (* Nothing else would close it before the switch ends. *)
            Eio.Cancel.protect (fun () ->
                try Eio.Resource.close socket with Eio.Io _ -> ());
            raise ex)
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
   raises it at the next use. Without a descriptor only the idle limit
   retires a connection. *)
let await_server_activity c =
  match Eio_unix.Resource.fd_opt c.socket with
  | Some fd -> Eio_unix.Fd.use fd Eio_unix.await_readable ~if_closed:Fun.id
  | None -> Eio.Fiber.await_cancel ()

(* Watched while idle (RFC 9112 §9.5): the server closing it or sending
   anything retires it, so one the server gave up on is never lent, and so
   does waiting past [idle_for]. The watch is a daemon, so an idle connection
   never holds its switch open. *)
let keep_idle t k c ~idle_for =
  let idle = idle_connections t in
  let kept = Option.value (Hashtbl.find_opt idle k) ~default:[] in
  match local_switch t with
  | None -> close_connection c
  | Some _ when List.length kept >= t.per_host -> close_connection c
  | Some sw ->
      Hashtbl.replace idle k (c :: kept);
      let stopped, stop_watch = Eio.Promise.create () in
      c.stop_watch <- Some stop_watch;
      Eio.Fiber.fork_daemon ~sw (fun () ->
          let retire =
            Eio.Fiber.first
              (fun () ->
                await_server_activity c;
                true)
              (fun () ->
                Eio.Fiber.first
                  (fun () ->
                    Eio.Time.Mono.sleep t.clock idle_for;
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
   to. *)
let server_spoke c =
  Eio.Buf_read.buffered_bytes c.reader > 0
  || (match c.tls_reads with Some reads -> reads.last_full | None -> false)
  ||
  match Eio_unix.Resource.fd_opt c.socket with
  | None -> false
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
  | None, (`GET | `HEAD | `DELETE | `OPTIONS | `Other _) -> []

(* RFC 9110 §9.2.2. *)
let is_idempotent = function
  | `GET | `HEAD | `PUT | `DELETE | `OPTIONS -> true
  | `POST | `PATCH | `Other _ -> false

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
            fail "a request field that cannot be written: %s" name
        | Error `Target -> fail "a request target that cannot be written");
        Option.iter (Eio.Buf_write.string oc) body)
  with
  | () -> ()
  | exception (Eio.Io _ as ex) -> raise (Unsent (Printexc.to_string ex))

(* Every 1xx before the final head is dropped (RFC 9110 §15.2), but a 101
   where the request asked to switch is the answer. Ending before a byte is
   [Unanswered], after which a request may be sent again. *)
let rec read_final_head ?(switching = false) c ~first =
  match Head.Response.read ~max:max_head c.reader with
  | Error `Closed when first -> raise Unanswered
  | Error `Closed -> fail "the server closed the connection mid-answer"
  | Error (`Malformed m) -> fail "a response that could not be read: %s" m
  | Ok head when switching && Status.to_int head.status = 101 -> head
  | Ok head when Status.to_int head.status < 200 ->
      read_final_head ~switching c ~first:false
  | Ok head -> head

let keep_alive_timeout headers =
  List.concat_map Field.elements (Field.all headers "keep-alive")
  |> List.find_map (fun e ->
      match String.split_on_char '=' e with
      | [ k; v ]
        when String.equal (String.lowercase_ascii (String.trim k)) "timeout" ->
          Option.map float_of_int (int_of_string_opt (String.trim v))
      | _ -> None)

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
        | Some s when s <= 1. -> None
        | Some s -> Some (Float.min (s -. 1.) t.idle_s)
        | None -> Some t.idle_s)

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
              status = Status.to_int head.status;
              headers =
                List.map
                  (fun (k, v) -> (String.lowercase_ascii k, v))
                  head.headers;
              body;
            },
            kept )
      | Error `Too_large -> fail "a response longer than %d bytes" t.max_body
      | Error (`Broken m) -> fail "a response cut short: %s" m
      | Error `Busy -> fail "a response that could not be held")

(* ------------------------------------------------------------------ *)
(* A call *)

(* A caller's own beside one of these is a request a reader can take two
   ways. *)
let client_fields = [ "host"; "content-length"; "transfer-encoding" ]

(* A kept connection first; a request that met a reused connection's end is
   sent once more where that is safe (RFC 9112 §9.3.2). Kept only if the
   response allows, and closed on any raise. *)
let exchange t ~headers ~body meth target ~reused =
  (match
     List.find_opt
       (fun (n, _) -> List.mem (String.lowercase_ascii n) client_fields)
       headers
   with
  | Some (n, _) -> fail "a request field the client writes itself: %s" n
  | None -> ());
  let k = pool_key target in
  let caller_closes = Field.has_element headers "connection" "close" in
  let rec attempt ~fresh =
    let c, was_kept =
      match if fresh then None else borrow_idle t k with
      | Some c -> (c, true)
      | None -> (connect t target, false)
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
    | exception Unsent _ when was_kept ->
        close_connection c;
        attempt ~fresh:true
    | exception Unanswered when was_kept && is_idempotent meth ->
        close_connection c;
        attempt ~fresh:true
    | exception ex ->
        close_connection c;
        raise ex
  in
  attempt ~fresh:false

let error_of_exn = function
  | Failed m -> Some (Unreachable m)
  | Unsent m -> Some (Unreachable ("the request was not sent: " ^ m))
  | Unanswered ->
      Some (Unreachable "the server closed the connection without answering")
  | (Eio.Io _ | End_of_file | Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _) as ex
    ->
      Some (Unreachable (Printexc.to_string ex))
  | _ -> None

(* Named by method, as OpenTelemetry names a client span, [HTTP] for any
   other so a name is never a caller's string; described by where it went,
   never its query, which may carry a credential. A 4xx or 5xx fails it. *)
let within_client_span meth uri f =
  let name =
    match meth with
    | (`GET | `HEAD | `POST | `PUT | `DELETE | `OPTIONS | `PATCH) as m ->
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
        Trace.add span [ ("http.response.status_code", `Int status) ];
        if status >= 400 then Trace.fail span (string_of_int status)
      and failed = function
        | Unreachable _ -> Trace.fail span "unreachable"
        | Timed_out _ -> Trace.fail span "timeout"
      in
      f ~answered ~failed)

let call t ?timeout_s ?(headers = []) ?body meth url =
  let uri = Uri.of_string url in
  within_client_span meth uri @@ fun ~answered ~failed ->
  let deadline = Option.value timeout_s ~default:t.timeout_s in
  let started = Eio.Time.Mono.now t.clock in
  let reused = ref false in
  let result =
    match
      Eio.Time.Timeout.run (Eio.Time.Timeout.seconds t.clock deadline)
        (fun () -> Ok (exchange t ~headers ~body meth (target_of uri) ~reused))
    with
    | Ok answer -> Ok answer
    | Error `Timeout -> Error (Timed_out deadline)
    | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
    | exception ex -> (
        match error_of_exn ex with Some e -> Error e | None -> raise ex)
  in
  L.debug (fun m ->
      m "%s %s: %s on a %s connection  (%.0f ms)"
        (Spindle_http.Meth.to_string meth)
        (Option.value (Uri.host uri) ~default:"?")
        (match result with
        | Ok r -> string_of_int r.status
        | Error e -> error_to_string e)
        (if !reused then "reused" else "new")
        (Mtime.Span.to_float_ns (Mtime.span started (Eio.Time.Mono.now t.clock))
        /. 1e6));
  (match result with Ok r -> answered r.status | Error e -> failed e);
  result

(* ------------------------------------------------------------------ *)
(* An answer read as it arrives *)

module Body = struct
  type t = {
    reader : Framing.reader;
    clock : Eio.Time.Mono.ty Eio.Resource.t;
    wait_s : float;
    mutable ended : bool;  (** read to its end *)
    mutable function_returned : bool;
  }

  (* Each wait bounded, never the whole: a stream's length is its own. After
     its function returns the connection is kept or closed, so a read reads
     nothing. *)
  let read b =
    if b.function_returned || b.ended then Ok `End
    else
      match
        Eio.Time.Timeout.run (Eio.Time.Timeout.seconds b.clock b.wait_s)
          (fun () ->
            Ok
              (Framing.read_some b.reader ~max:max_int ~reserve:(fun _ -> true)))
      with
      | Error `Timeout -> Error (Timed_out b.wait_s)
      | Ok (Ok (`Data s)) -> Ok (`Data s)
      | Ok (Ok `End) ->
          b.ended <- true;
          Ok `End
      | Ok (Error (`Broken m)) ->
          Error (Unreachable ("an answer cut short: " ^ m))
      | Ok (Error (`Too_large | `Busy)) ->
          Error (Unreachable "an answer that could not be held")
      | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
      | exception ex -> (
          match error_of_exn ex with Some e -> Error e | None -> raise ex)
end

type answer = { status : int; headers : (string * string) list; body : Body.t }

(* The connection and the answer's head, retried as a call is. *)
let open_answer t ~headers ~body meth target =
  (match
     List.find_opt
       (fun (n, _) -> List.mem (String.lowercase_ascii n) client_fields)
       headers
   with
  | Some (n, _) -> fail "a request field the client writes itself: %s" n
  | None -> ());
  let k = pool_key target in
  let rec attempt ~fresh =
    let c, was_kept =
      match if fresh then None else borrow_idle t k with
      | Some c -> (c, true)
      | None -> (connect t target, false)
    in
    match
      send_request c meth target ~headers ~body;
      read_final_head c ~first:true
    with
    | head -> (c, head)
    | exception Unsent _ when was_kept ->
        close_connection c;
        attempt ~fresh:true
    | exception Unanswered when was_kept && is_idempotent meth ->
        close_connection c;
        attempt ~fresh:true
    | exception ex ->
        close_connection c;
        raise ex
  in
  attempt ~fresh:false

(* The span includes the reading: a stream's length is its cost. *)
let stream t ?timeout_s ?read_timeout_s ?(headers = []) ?body meth url f =
  let uri = Uri.of_string url in
  within_client_span meth uri @@ fun ~answered ~failed ->
  let deadline = Option.value timeout_s ~default:t.timeout_s in
  let wait_s = Option.value read_timeout_s ~default:deadline in
  let caller_closes = Field.has_element headers "connection" "close" in
  match
    Eio.Time.Timeout.run (Eio.Time.Timeout.seconds t.clock deadline) (fun () ->
        let target = target_of uri in
        Ok (target, open_answer t ~headers ~body meth target))
  with
  | Error `Timeout ->
      failed (Timed_out deadline);
      Error (Timed_out deadline)
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex -> (
      match error_of_exn ex with
      | Some e ->
          failed e;
          Error e
      | None -> raise ex)
  | Ok (target, (c, head)) -> (
      answered (Status.to_int head.status);
      match Framing.of_response ~request_meth:meth head with
      | Error m ->
          close_connection c;
          Error (Unreachable ("a response whose length cannot be told: " ^ m))
      | Ok framing ->
          let b =
            {
              Body.reader =
                Framing.reader framing c.reader ~max_trailer:max_head;
              clock = t.clock;
              wait_s;
              ended = false;
              function_returned = false;
            }
          in
          (* Kept only when read to the end and neither side said close: an
             unread body is the next answer's first bytes. *)
          let finally () =
            b.function_returned <- true;
            match (b.ended, keep_idle_for t head framing ~caller_closes) with
            | true, Some idle_for -> keep_idle t (pool_key target) c ~idle_for
            | true, None | false, (Some _ | None) -> close_connection c
          in
          Ok
            (Fun.protect ~finally (fun () ->
                 f
                   {
                     status = Status.to_int head.status;
                     headers =
                       List.map
                         (fun (k, v) -> (String.lowercase_ascii k, v))
                         head.headers;
                     body = b;
                   })))

type events_end =
  | Finished of string option
  | Stopped of string option
  | Refused of response

let is_event_stream headers =
  match
    Option.map Spindle_http.Media_type.parse (Field.find headers "content-type")
  with
  | Some (Ok { type_ = "text"; subtype = "event-stream"; _ }) -> true
  | Some (Ok _ | Error _) | None -> false

let events t ?timeout_s ?read_timeout_s ?(headers = []) ?last_event_id url
    on_event =
  let headers =
    [ ("Accept", "text/event-stream"); ("Cache-Control", "no-cache") ]
    @ (match last_event_id with
      | Some id -> [ ("Last-Event-ID", id) ]
      | None -> [])
    @ headers
  in
  Result.join
    (stream t ?timeout_s ?read_timeout_s ~headers `GET url (fun a ->
         if not (a.status = 200 && is_event_stream a.headers) then
           (* Not a stream: the answer, read whole as a call's is. *)
           let b = Buffer.create 256 in
           let rec whole () =
             match Body.read a.body with
             | Ok (`Data s) ->
                 Buffer.add_string b s;
                 if Buffer.length b > t.max_body then
                   Error
                     (Unreachable
                        (Printf.sprintf "a response longer than %d bytes"
                           t.max_body))
                 else whole ()
             | Ok `End ->
                 Ok
                   (Refused
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
                 | Error m -> Error (Unreachable m))
           in
           next ()))

(* ------------------------------------------------------------------ *)
(* A WebSocket *)

type websocket_error =
  | Failed of error
  | Refused of response
  | Ended of Websocket.error

let websocket_error_to_string = function
  | Failed e -> error_to_string e
  | Refused r -> Printf.sprintf "answered %d, which opens no socket" r.status
  | Ended e -> Websocket.error_to_string e

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
  | Some s -> fail "a scheme a WebSocket is not opened over: %s" s
  | None -> fail "a URL with no scheme"

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
         (Some (Websocket.accept_key key)))
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

let open_websocket t ?timeout_s ?(headers = []) ?keep_alive_s ?max_message
    protocol url f =
  let deadline = Option.value timeout_s ~default:t.timeout_s in
  let key = Base64.encode_string (Mirage_crypto_rng.generate 16) in
  Eio.Switch.run @@ fun sw ->
  let opened =
    match
      Eio.Time.Timeout.run (Eio.Time.Timeout.seconds t.clock deadline)
        (fun () ->
          (match
             List.find_opt
               (fun (n, _) ->
                 let n = String.lowercase_ascii n in
                 List.mem n client_fields || List.mem n handshake_fields)
               headers
           with
          | Some (n, _) -> fail "a request field the client writes itself: %s" n
          | None -> ());
          let target = target_of (http_uri_of_ws (Uri.of_string url)) in
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
    | Error `Timeout -> Error (Failed (Timed_out deadline))
    | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
    | exception ex -> (
        match error_of_exn ex with
        | Some e -> Error (Failed e)
        | None -> raise ex)
  in
  match opened with
  | Error _ as e -> e
  | Ok (`Refused (head, body)) ->
      Error
        (Refused
           {
             status = Status.to_int head.status;
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
          Error (Failed (Unreachable m))
      | Ok () ->
          let ended =
            Eio.Buf_write.with_flow c.flow (fun writer ->
                Websocket.run_client ?keep_alive_s ?max_message
                  ~mask:(fun () -> Mirage_crypto_rng.generate 4)
                  protocol
                  {
                    Spindle_http.Connection.reader = c.reader;
                    writer;
                    clock = t.clock;
                    send_timeout_s = deadline;
                    stopping = fst (Eio.Promise.create ());
                  }
                  f)
          in
          close_connection c;
          Result.map_error (fun e -> Ended e) ended)

(* One line when it ends: a warning when it never opened or did not end
   cleanly. Never the query, which may carry a credential. *)
let websocket t ?timeout_s ?headers ?keep_alive_s ?max_message protocol url f =
  let started = Eio.Time.Mono.now t.clock in
  let result =
    open_websocket t ?timeout_s ?headers ?keep_alive_s ?max_message protocol url
      f
  in
  let uri = Uri.of_string url in
  let host = Option.value (Uri.host uri) ~default:"?" in
  let clean =
    match result with
    | Ok _
    | Error
        (Ended
           (Websocket.Closed
              { code = Websocket.Normal | Websocket.Going_away; _ })) ->
        true
    | Error (Failed _ | Refused _ | Ended _) -> false
  in
  let how =
    match result with
    | Ok _ -> "closed"
    | Error e -> websocket_error_to_string e
  in
  (if clean then L.info else L.warn) (fun m ->
      m "socket to %s%s ended: %s" host (Uri.path uri) how
        ~tags:
          (Spindle_http.Log.tags
             [
               ("server.address", `String host);
               ("url.path", `String (Uri.path uri));
               ( "duration",
                 `Int
                   (Int64.to_int
                      (Mtime.Span.to_uint64_ns
                         (Mtime.span started (Eio.Time.Mono.now t.clock)))) );
               ("spindle.websocket.ended", `String how);
             ]));
  result

(* ------------------------------------------------------------------ *)
(* Spans, sent to a collector *)

module Otlp = struct
  module V = Wiretype.Value

  let batch_size = 512
  let queue_limit = 2048
  let send_interval_s = 5.

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
          ("startTimeUnixNano", V.String (string_of_int s.start_ns));
          ("endTimeUnixNano", V.String (string_of_int s.end_ns));
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
            | Ok r when r.status >= 200 && r.status < 300 -> ()
            | Ok r ->
                L.warn (fun m ->
                    m "the collector refused %d spans: %d" (List.length spans)
                      r.status)
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
              Eio.Time.Mono.sleep client.clock send_interval_s;
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
