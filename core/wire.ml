module Status = Spindle_http.Status
module Meth = Spindle_http.Meth
module Field = Spindle_http.Field
module L = (val Logs.src_log Log.http : Logs.LOG)

type body =
  | Nothing
  | Bytes of string
  | Chunks of Response.stream
  | Counted of int * Response.stream
  | Until_close of Response.stream
  | Connection of (Response.connection -> unit)

(* [closing] asks for the connection to end; the loop decides. *)
type t = {
  status : Status.t;
  headers : (string * string) list;
  body : body;
  closing : bool;
  refused : Refusal.t option;
  gzip : int option;
}

(* Framing fields are the server's alone: a second length or a keep-alive
   beside its own is an answer a reader can take two ways. *)
let framing_fields =
  [
    "content-length";
    "transfer-encoding";
    "connection";
    "keep-alive";
    "upgrade";
    "te";
    "trailer";
  ]

(* Written from the response or the server; as a plain header one would be
   a second answer, and a cookie would miss the Secure decision. *)
let derived_fields = [ "content-type"; "set-cookie"; "date"; "x-request-id" ]

let is_reserved_field (name, _) =
  let name = String.lowercase_ascii name in
  List.mem name framing_fields || List.mem name derived_fields

(* RFC 9110 §15: a 1xx is interim, and a client given one waits for more. *)
let is_final status =
  let n = Status.to_int status in
  n >= 200 && n <= 599

(* No length either: some clients would wait for the body it names. *)
let is_bodiless status =
  match Status.to_int status with 204 | 304 -> true | _ -> false

(* RFC 9110 §6.6.1: a server with a clock dates every 2xx, 3xx and 4xx. *)
let with_date req status headers =
  match Status.to_int status with
  | n when n >= 200 && n < 500 ->
      headers @ [ ("date", Spindle_http.Write.date (Request.now req)) ]
  | _ -> headers

(* RFC 9110 §7.8: only a protocol offered with [Connection: upgrade], and
   never on HTTP/1.0. *)
let upgrade_offered req protocol =
  let fields = Request.headers req in
  match Request.version req with
  | Spindle_http.Head.Http_1_0 -> false
  | Spindle_http.Head.Http_1_1 ->
      Field.has_element fields "connection" "upgrade"
      && Field.has_element fields "upgrade" protocol

(* An entity tag names one representation. *)
let gzip_tag headers =
  List.map
    (fun (k, v) ->
      if String.equal (String.lowercase_ascii k) "etag" then
        match
          Result.bind (Spindle_http.Etag.parse v) (fun t ->
              Spindle_http.Etag.to_string { t with opaque = t.opaque ^ "-gzip" })
        with
        | Ok tag -> (k, tag)
        | Error _ -> (k, v)
      else (k, v))
    headers

(* A response that cannot be written as it stands becomes a 500, logged. *)
let rec render ?gzip req r =
  let refuse_with_500 detail =
    L.err (fun m ->
        m "%s %s: %s"
          (Meth.to_string (Request.meth req))
          (Request.path req) detail);
    render ?gzip req (Response.refusal (Refusal.internal ~detail))
  in
  let secure = Request.secure req in
  let status = Response.status r in
  let headers =
    Option.to_list
      (Option.map (fun ct -> ("content-type", ct)) (Response.content_type r))
    @ Response.headers r
    @ ("x-request-id", Request.id req)
      :: List.map
           (fun c ->
             ( "set-cookie",
               Cookie_repr.to_header ~secure ~now:(Request.now req) c ))
           (Response.cookies r)
  in
  let headers = with_date req status headers in
  let is_head = match Request.meth req with `HEAD -> true | _ -> false in
  let is_http_1_0 =
    match Request.version req with
    | Spindle_http.Head.Http_1_0 -> true
    | Spindle_http.Head.Http_1_1 -> false
  in
  let closing = Response.closes_connection r and refused = Response.refused r in
  let wire ?gzip headers body =
    { status; headers; body; closing; refused; gzip }
  in
  let with_gzip headers = gzip_tag headers @ [ ("content-encoding", "gzip") ] in
  (* RFC 9110 §15.5.22: a 426 names the protocol in Upgrade. *)
  let asks_upgrade (name, _) =
    Status.equal status `Upgrade_required
    && String.equal (String.lowercase_ascii name) "upgrade"
  in
  match
    ( List.find_opt (fun f -> not (Field.is_writable f)) headers,
      List.find_opt
        (fun f -> is_reserved_field f && not (asks_upgrade f))
        (Response.headers r) )
  with
  | Some (k, _), _ ->
      refuse_with_500 (Printf.sprintf "a header that cannot be written: %S" k)
  | None, Some (k, _) ->
      refuse_with_500
        (Printf.sprintf "a header only the framework writes: %S" k)
  | None, None -> (
      match Response.content r with
      | Response.Takeover { protocol; _ }
        when not (upgrade_offered req protocol) ->
          refuse_with_500
            (Printf.sprintf "a takeover to %S, which the client did not offer"
               protocol)
      (* After the 101 the connection is the protocol's, even for HEAD. *)
      | Response.Takeover { protocol; handle } ->
          wire
            (headers @ [ ("upgrade", protocol); ("connection", "upgrade") ])
            (Connection (if is_head then fun _ -> () else handle))
      | (Response.Buffered _ | Response.Stream _) when not (is_final status) ->
          refuse_with_500
            (Printf.sprintf "%d, which is not a final status"
               (Status.to_int status))
      | (Response.Buffered _ | Response.Stream _) when is_bodiless status ->
          wire headers Nothing
      | Response.Buffered s -> (
          match gzip with
          | Some level ->
              let z = Gzip.string ~level s in
              wire
                (with_gzip headers
                @ [ ("content-length", string_of_int (String.length z)) ])
                (if is_head then Nothing else Bytes z)
          | None ->
              wire
                (headers
                @ [ ("content-length", string_of_int (String.length s)) ])
                (if is_head then Nothing else Bytes s))
      | Response.Stream ({ length = Some n; _ } as stream) ->
          wire
            (headers @ [ ("content-length", string_of_int n) ])
            (if is_head then Nothing else Counted (n, stream))
      (* HTTP/1.0 has no chunked coding (RFC 9112 §6.1), so a body of no
         known length ends where the connection does. *)
      | Response.Stream stream when is_http_1_0 ->
          let headers =
            match gzip with Some _ -> with_gzip headers | None -> headers
          in
          wire ?gzip headers (if is_head then Nothing else Until_close stream)
      | Response.Stream stream ->
          let headers =
            match gzip with Some _ -> with_gzip headers | None -> headers
          in
          wire ?gzip
            (headers @ [ ("transfer-encoding", "chunked") ])
            (if is_head then Nothing else Chunks stream))
