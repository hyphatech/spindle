(* What a route returns: its model, what it describes, and how its result
   becomes a response. Private, so a model is made only by [Returns]. *)

module Websocket = Spindle_http.Websocket
module Status = Spindle_http.Status
module L = (val Logs.src_log Log.http : Logs.LOG)

type 'r t =
  | Json : {
      status : Status.t;
      description : 'a Wiretype.t;
      examples : 'a list;
    }
      -> ('a, Refusal.t) result t
  | Json_response : {
      statuses : (Status.t * string) list;
      description : 'a Wiretype.t;
      examples : 'a list;
    }
      -> (Status.t * 'a, Refusal.t) result t
  | Html : (string, Refusal.t) result t
  | Text : (string, Refusal.t) result t
  | Empty : Status.t -> (unit, Refusal.t) result t
  | Empty_response : (Status.t * string) list -> (Status.t, Refusal.t) result t
  | Response : (Response.t, Refusal.t) result t
  | Events : {
      declared : 's Event.declared list;
      keep_alive_s : float;
    }
      -> ('s Event.stream, Refusal.t) result t
  | Websocket : {
      protocol : ('c, 's) Websocket.protocol;
      keep_alive_s : float option;
      max_message : int option;
    }
      -> ( ('c, 's) Websocket.t -> (unit, Websocket.error) result,
           Refusal.t )
         result
         t

type shape =
  | Json : {
      status : Status.t;
      description : 'a Wiretype.t;
      examples : 'a list;
    }
      -> shape
  | Json_response : {
      statuses : (Status.t * string) list;
      description : 'a Wiretype.t;
      examples : 'a list;
    }
      -> shape
  | Html
  | Text
  | Empty of Status.t
  | Empty_response of (Status.t * string) list
  | Response
  | Events : 's Event.declared list -> shape
  | Websocket : ('c, 's) Websocket.protocol -> shape

let shape : type r. r t -> shape = function
  | Json { status; description; examples } ->
      Json { status; description; examples }
  | Json_response { statuses; description; examples } ->
      Json_response { statuses; description; examples }
  | Html -> Html
  | Text -> Text
  | Empty status -> Empty status
  | Empty_response statuses -> Empty_response statuses
  | Response -> Response
  | Events { declared; keep_alive_s = _ } -> Events declared
  | Websocket { protocol; keep_alive_s = _; max_message = _ } ->
      Websocket protocol

(* On any of the field's lines, since several are one list (RFC 9110 §5.3);
   a subprotocol is matched as written, as RFC 6455 §4.1 names one. *)
let has_token req field token =
  Spindle_http.Field.has_element (Request.headers req) field token

let offers_protocol req name =
  List.exists
    (fun v -> List.exists (String.equal name) (Spindle_http.Field.elements v))
    (Spindle_http.Field.all (Request.headers req) "sec-websocket-protocol")

(* RFC 6455 §4.2.1, checked before the handler runs: the 101's fields, or
   why there is none. A request for no socket, or another version, is told
   what to ask for. *)
let handshake protocol req =
  let asked =
    has_token req "upgrade" "websocket"
    &&
    match Request.version req with
    | Spindle_http.Head.Http_1_1 -> true
    | Spindle_http.Head.Http_1_0 -> false
  in
  let refuse_upgrade headers message =
    Error
      (Refusal.make Refusal.Code.upgrade_required
         ~headers:(("upgrade", "websocket") :: headers)
         message)
  in
  if not asked then
    refuse_upgrade [] "This address opens a WebSocket, and nothing else."
  else if
    not
      (Option.equal String.equal
         (Request.header req "sec-websocket-version")
         (Some "13"))
  then
    refuse_upgrade
      [ ("sec-websocket-version", "13") ]
      "This server speaks version 13 of WebSockets."
  else
    let key =
      Option.value (Request.header req "sec-websocket-key") ~default:""
    in
    let problem at code message = Some { Refusal.at; code; message } in
    let problems =
      List.filter_map Fun.id
        [
          (if has_token req "connection" "upgrade" then None
           else
             problem "header.connection" "required"
               "A WebSocket is opened with Connection: upgrade.");
          (match Base64.decode key with
          | Ok k when String.length k = 16 -> None
          | Ok _ | Error _ ->
              problem "header.sec-websocket-key" "malformed"
                "This is not a WebSocket key.");
          (match Websocket.subprotocol protocol with
          | Some name when not (offers_protocol req name) ->
              problem "header.sec-websocket-protocol" "required"
                (Printf.sprintf "This socket speaks %s, which was not offered."
                   name)
          | Some _ | None -> None);
        ]
    in
    match problems with
    | _ :: _ -> Error (Refusal.invalid problems)
    | [] ->
        Ok
          (("sec-websocket-accept", Websocket.accept_key key)
          ::
          (match Websocket.subprotocol protocol with
          | Some name -> [ ("sec-websocket-protocol", name) ]
          | None -> []))

let upgrade : type r.
    r t -> Request.t -> ((string * string) list, Refusal.t) result =
 fun returns req ->
  match returns with
  | Websocket { protocol; _ } -> handshake protocol req
  | Json _ | Json_response _ | Html | Text | Empty _ | Empty_response _
  | Response | Events _ ->
      Ok []

(* It outlives its answer, so it logs a line of its own when it ends. *)
let run_socket ~path ?keep_alive_s ?max_message protocol handler
    (c : Response.connection) =
  let started = Eio.Time.Mono.now c.clock in
  let log_end how =
    L.info (fun m ->
        m "socket on %s ended: %s" path how
          ~tags:
            (Log.tags
               [
                 ("url.path", `String path);
                 ( "duration",
                   `Int
                     (Int64.to_int
                        (Mtime.Span.to_uint64_ns
                           (Mtime.span started (Eio.Time.Mono.now c.clock)))) );
                 ("spindle.websocket.ended", `String how);
               ]))
  in
  match Websocket.run_server ?keep_alive_s ?max_message protocol c handler with
  | Ok () -> log_end "closed"
  | Error e -> log_end (Websocket.error_to_string e)
  | exception (Eio.Cancel.Cancelled _ as ex) ->
      log_end "connection closed";
      raise ex
  | exception _ -> log_end "its handler raised"

(* The type keeps out another stream's kinds; one of this stream's that the
   route did not declare is still sent, and the route's bug logged. *)
let send_checked ~pattern declared send e =
  (match Event.name e with
  | Some n
    when not
           (List.exists
              (fun d -> String.equal (Event.declared_name d) n)
              declared) ->
      L.warn (fun m ->
          m "%s sent the event %s, which it does not declare" pattern n)
  | Some _ | None -> ());
  send (Event.to_string e)

(* What the route set goes with a success, never with a refusal. *)
let respond : type r.
    r t ->
    pattern:string ->
    path:string ->
    upgrade:(string * string) list ->
    cookies:Cookie.t list ->
    headers:(string * string) list ->
    r ->
    Response.t =
 fun returns ~pattern ~path ~upgrade ~cookies ~headers r ->
  let with_outgoing response =
    Response.add_cookies cookies (Response.add_headers headers response)
  in
  let refuse = Response.refusal in
  match returns with
  | Json { status; description; examples = _ } -> (
      match r with
      | Error refusal -> refuse refusal
      | Ok v -> Response.json ~status ~headers ~cookies description v)
  | Json_response { statuses = _; description; examples = _ } -> (
      match r with
      | Error refusal -> refuse refusal
      | Ok (status, v) -> Response.json ~status ~headers ~cookies description v)
  | Html -> (
      match r with
      | Error refusal -> refuse refusal
      | Ok page -> Response.html ~headers ~cookies page)
  | Text -> (
      match r with
      | Error refusal -> refuse refusal
      | Ok text -> Response.make ~headers ~cookies text)
  | Empty status -> (
      match r with
      | Error refusal -> refuse refusal
      | Ok () -> Response.empty ~status ~headers ~cookies ())
  | Empty_response _ -> (
      match r with
      | Error refusal -> refuse refusal
      | Ok status -> Response.empty ~status ~headers ~cookies ())
  | Response -> (
      match r with
      | Error refusal -> Response.refusal refusal
      | Ok p -> with_outgoing p)
  | Events { declared; keep_alive_s } -> (
      match r with
      | Error refusal -> refuse refusal
      | Ok stream ->
          with_outgoing
            (Response.events ~keep_alive_s (fun send ->
                 stream (send_checked ~pattern declared send))))
  | Websocket { protocol; keep_alive_s; max_message } -> (
      match r with
      | Error refusal -> refuse refusal
      | Ok handler ->
          with_outgoing
            (Response.takeover ~protocol:"websocket" ~headers:upgrade
               (run_socket ~path ?keep_alive_s ?max_message protocol handler)))

(* A route with one status sets it itself, so only a list is checked. *)
let declares shape status =
  let is_listed statuses =
    List.exists (fun (s, _) -> Status.equal s status) statuses
  in
  match shape with
  | Json_response { statuses; _ } | Empty_response statuses ->
      is_listed statuses
  | Json _ | Html | Text | Empty _ | Response | Events _ | Websocket _ -> true
