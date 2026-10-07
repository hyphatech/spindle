(* The conformance table: every requirement of RFC 9112, and of the parts of
   RFC 9110 that bind a message's handling, that Spindle meets -- a row
   each, named by its section. Reviewing an HTTP implementation by example
   misses the MUST nobody thought of; a row per requirement is where a
   missing one has somewhere to be noticed.

   The rows are data, and one function runs a row: through [Head], through
   [Framing], or through the whole server over a socket. Every row is read
   whole and one byte at a time, and a property reads every row again at
   splits a generator chooses, because a reader over a socket sees bytes in
   whatever pieces arrived and must not depend on them.

   Then what no example gives: writing then reading is the identity; no
   input crashes, hangs or reads past a limit; no sequence of requests on
   one connection is answered other than one response each, in order; and a
   referee, httpun's parser, reading every generated and mutated head beside
   ours, with every place the two disagree on purpose listed with its
   reason. Two parsers reading one stream differently -- a proxy's and ours
   -- is the danger all of this guards against, so disagreement is the
   thing measured. *)

module Head = Spindle_http.Head
module Framing = Spindle_http.Framing
module Field = Spindle_http.Field
module Write = Spindle_http.Write
module Meth = Spindle_http.Meth
module Status = Spindle_http.Status
open Spindle.Syntax

(* ------------------------------------------------------------------ *)
(* Delivery *)

(* A flow that hands its reader the pieces a test chose, one read each: the
   read boundaries a socket would choose, chosen instead. [ends] is what it
   raises once they are read: the end of input, or a connection failing. *)
module Pieces = struct
  type t = { mutable left : string list; ends : exn }

  let read_methods = []

  let single_read t buf =
    match t.left with
    | [] -> raise t.ends
    | p :: rest ->
        let n = min (String.length p) (Cstruct.length buf) in
        Cstruct.blit_from_string p 0 buf 0 n;
        t.left <-
          (if n = String.length p then rest
           else String.sub p n (String.length p - n) :: rest);
        n
end

let source ?(ends = End_of_file) pieces =
  Eio.Resource.T
    ( { Pieces.left = List.filter (fun p -> String.length p > 0) pieces; ends },
      Eio.Flow.Pi.source (module Pieces) )

type delivery = Whole | Bytewise | At of int list

let split delivery s =
  let n = String.length s in
  match delivery with
  | Whole -> [ s ]
  | Bytewise -> List.init n (fun i -> String.make 1 s.[i])
  | At cuts ->
      let cuts =
        List.sort_uniq Int.compare (List.filter (fun c -> c > 0 && c < n) cuts)
      in
      let rec pieces from = function
        | [] -> [ String.sub s from (n - from) ]
        | c :: rest -> String.sub s from (c - from) :: pieces c rest
      in
      pieces 0 cuts

(* Where [sub] first occurs in [s] at or after [from]. *)
let find_from s from sub =
  let n = String.length s and m = String.length sub in
  let rec at i =
    if i + m > n then None
    else if String.equal (String.sub s i m) sub then Some i
    else at (i + 1)
  in
  at from

let split_on s sep =
  let rec pieces from =
    match find_from s from sep with
    | Some i -> String.sub s from (i - from) :: pieces (i + String.length sep)
    | None -> [ String.sub s from (String.length s - from) ]
  in
  pieces 0

let delivery_name = function
  | Whole -> "whole"
  | Bytewise -> "a byte at a time"
  | At cuts -> "cut at " ^ String.concat "," (List.map string_of_int cuts)

(* ------------------------------------------------------------------ *)
(* Reading a request as the server's pieces do *)

let max_head = 1024
let max_body = 4096

type reading =
  | Head_refused of Head.error
  | Unframed of Head.Request.t * int
  | Broken of Head.Request.t
  | Too_large of Head.Request.t
  | Read of Head.Request.t * string

(* A body read a part at a time, as a route reading it as it arrives does. *)
let read_parts r ~max ~reserve =
  let b = Buffer.create 64 in
  let rec parts () =
    match Framing.read_some r ~max ~reserve with
    | Ok `End -> Ok (Buffer.contents b)
    | Ok (`Data s) ->
        Buffer.add_string b s;
        parts ()
    | Error e -> Error e
  in
  parts ()

let read_with ~body ~max ~max_body delivery bytes =
  let ic =
    Eio.Buf_read.of_flow ~initial_size:64 ~max_size:max
      (source (split delivery bytes))
  in
  match Head.Request.read ~max ic with
  | Error e -> Head_refused e
  | Ok head -> (
      match Framing.of_request head with
      | Error (status, _) -> Unframed (head, Status.to_int status)
      | Ok framing -> (
          let r = Framing.reader framing ic ~max_trailer:max in
          match body r ~max:max_body ~reserve:(fun _ -> true) with
          | Ok body -> Read (head, body)
          | Error (`Broken _) -> Broken head
          | Error `Too_large -> Too_large head
          | Error `Busy -> Alcotest.fail "nothing is reserved here"))

let version_name = function Head.Http_1_0 -> "1.0" | Head.Http_1_1 -> "1.1"

let show_head (h : Head.Request.t) =
  Printf.sprintf "%s %S HTTP/%s [%s] for %s" (Meth.to_string h.meth) h.target
    (version_name h.version)
    (String.concat "; "
       (List.map (fun (k, v) -> Printf.sprintf "%S: %S" k v) h.headers))
    (Option.value h.host ~default:"no host")

(* One spelling of a reading, so two can be compared and a failure read. *)
let show = function
  | Head_refused Head.Closed -> "closed before a head"
  | Head_refused (Head.Refused (s, _)) ->
      Printf.sprintf "head refused %d" (Status.to_int s)
  | Unframed (h, s) -> Printf.sprintf "%s, framing refused %d" (show_head h) s
  | Broken h -> show_head h ^ ", body broken"
  | Too_large h -> show_head h ^ ", body too large"
  | Read (h, body) -> Printf.sprintf "%s, body %S" (show_head h) body

(* Every request is read twice, whole and a part at a time, and the two must
   agree: a body read as it arrives ends where the body does, at every split
   a row or a generator chooses. *)
let read ?(max = max_head) ?(max_body = max_body) delivery bytes =
  let whole = read_with ~body:Framing.read ~max ~max_body delivery bytes in
  let parts = read_with ~body:read_parts ~max ~max_body delivery bytes in
  if String.equal (show whole) (show parts) then whole
  else
    Alcotest.failf "read whole: %s\nread in parts: %s" (show whole) (show parts)

(* ------------------------------------------------------------------ *)
(* Reading a response as a client's pieces do *)

type response_reading =
  | Response_closed
  | Response_malformed
  | Response_unframed of Head.Response.t
  | Response_broken of Head.Response.t
  | Response_too_large of Head.Response.t
  | Response_read of Head.Response.t * string

let read_response ?(max = max_head) ?(max_body = max_body) ~meth delivery bytes
    =
  let ic =
    Eio.Buf_read.of_flow ~initial_size:64 ~max_size:max
      (source (split delivery bytes))
  in
  match Head.Response.read ~max ic with
  | Error `Closed -> Response_closed
  | Error (`Malformed _) -> Response_malformed
  | Ok head -> (
      match Framing.of_response ~request_meth:meth head with
      | Error _ -> Response_unframed head
      | Ok framing -> (
          let r = Framing.reader framing ic ~max_trailer:max in
          match Framing.read r ~max:max_body ~reserve:(fun _ -> true) with
          | Ok body -> Response_read (head, body)
          | Error (`Broken _) -> Response_broken head
          | Error `Too_large -> Response_too_large head
          | Error `Busy -> Alcotest.fail "nothing is reserved here"))

let show_response_head (h : Head.Response.t) =
  Printf.sprintf "HTTP/%s %d %S [%s]%s" (version_name h.version)
    (Status.to_int h.status) h.reason
    (String.concat "; "
       (List.map (fun (k, v) -> Printf.sprintf "%S: %S" k v) h.headers))
    (if Head.Response.keep_alive h then "" else ", not kept")

let show_response = function
  | Response_closed -> "closed before a head"
  | Response_malformed -> "malformed"
  | Response_unframed h -> show_response_head h ^ ", framing refused"
  | Response_broken h -> show_response_head h ^ ", body broken"
  | Response_too_large h -> show_response_head h ^ ", body too large"
  | Response_read (h, body) ->
      Printf.sprintf "%s, body %S" (show_response_head h) body

(* ------------------------------------------------------------------ *)
(* The server the whole-server rows are sent to *)

let id = Spindle.Path.str "id"
let code = Spindle.Path.int "code"

(* What a handler that frames its own answer would write in each field: the
   length that desyncs a kept connection, the coding a stream already has. *)
let framing_value name =
  match String.lowercase_ascii name with
  | "content-length" -> "0"
  | "transfer-encoding" -> "chunked"
  | "connection" -> "keep-alive"
  | "keep-alive" -> "timeout=5"
  | "upgrade" -> "h2c"
  | "te" -> "trailers"
  | _ -> "x-t"

let signed_out =
  Spindle.Refusal.Code.make ~challenge:{|Test realm="t"|} "signed_out"
    ~status:`Unauthorized ~doc:"Nobody is signed in."

let routes =
  [
    Spindle.get
      Spindle.Path.(s "id" / id)
      Spindle.Returns.response
      (let+ id = Spindle.param id in
       Ok (Spindle.Response.make id));
    Spindle.post
      Spindle.Path.(s "read" / id)
      Spindle.Returns.response
      (let+ id = Spindle.param id and+ body = Spindle.body in
       Ok (Spindle.Response.make (id ^ "=" ^ body)));
    Spindle.post
      Spindle.Path.(s "ignore" / id)
      Spindle.Returns.response
      (let+ id = Spindle.param id in
       Ok (Spindle.Response.make id));
    (* What a trailer would say, had it been merged into the head. *)
    Spindle.post
      Spindle.Path.(s "x-id")
      Spindle.Returns.response
      (let+ _ = Spindle.body
       and+ v = Spindle.Header.optional "x-id" Spindle.Codec.string in
       Ok (Spindle.Response.make (Option.value v ~default:"none")));
    Spindle.get
      Spindle.Path.(s "nothing")
      Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.empty ())));
    Spindle.get
      Spindle.Path.(s "close")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok (Spindle.Response.close_connection (Spindle.Response.make "bye"))));
    (* A handler writing a field only the server may, named in the path. *)
    Spindle.get
      Spindle.Path.(s "sets" / id)
      Spindle.Returns.response
      (let+ name = Spindle.param id in
       Ok
         (Spindle.Response.make ~headers:[ (name, framing_value name) ] "hello"));
    Spindle.get
      Spindle.Path.(s "stream-length")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.stream
               ~headers:[ ("content-length", "2") ]
               (fun send -> send "ab"))));
    Spindle.get
      Spindle.Path.(s "status" / code)
      Spindle.Returns.response
      (let+ n = Spindle.param code in
       Ok (Spindle.Response.make ~status:(Status.of_int n) "hello"));
    Spindle.get
      Spindle.Path.(s "stream")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok
            (Spindle.Response.stream (fun send ->
                 Result.bind (send "a") (fun () -> send "b")))));
    Spindle.get
      Spindle.Path.(s "upgrade")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Ok (Spindle.Response.takeover ~protocol:"echo" (fun _ -> ()))));
    Spindle.get
      Spindle.Path.(s "host")
      Spindle.Returns.response
      (Spindle.Dep.map
         (fun r ->
           Ok
             (Spindle.Response.make
                (Option.value (Spindle.Request.host r) ~default:"none")))
         Spindle.request);
    Spindle.get
      Spindle.Path.(s "away")
      Spindle.Returns.response
      (Spindle.Dep.return (Ok (Spindle.Response.redirect "/id/there")));
    Spindle.get ~refuses:[ signed_out ]
      Spindle.Path.(s "private")
      Spindle.Returns.response
      (Spindle.Dep.return
         (Error (Spindle.Refusal.make signed_out "Please sign in.")));
  ]

let app = Spindle.Test.app routes
let max_body_on_the_server = 64
let max_head_on_the_server = 1024
let discard_on_the_server = 1024

(* RFC 9110 §5.6.7's example instant, and how it is written. *)
let example_instant = 784_111_777_000
let example_date = "Sun, 06 Nov 1994 08:49:37 GMT"

(* The server, on [In_memory]'s virtual time, and the way to connect to
   it: each piece a row sends is read before the next is sent, so the
   server reads at the boundaries the row chose. *)
let serve ~sw env =
  let listening, connect = In_memory.listen ~piecewise:true () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Spindle.Server.serve_on
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~domain_mgr:(Eio.Stdenv.domain_mgr env)
        ~domains:4
        ~now:(fun () -> example_instant)
        ~max_body:max_body_on_the_server
        ~max_header_bytes:max_head_on_the_server
        ~discard_limit:discard_on_the_server [ listening ] app;
      `Stop_daemon);
  connect

(* What came back, read by the test's own reader: a status line, fields,
   and a body by whatever the answer says its length is. *)
type answered = {
  status : int;
  headers : (string * string) list;
  body : string;
}

let read_answer ~head r =
  let line = Eio.Buf_read.line r in
  let status = int_of_string (String.sub line 9 3) in
  let rec fields acc =
    match Eio.Buf_read.line r with
    | "" -> List.rev acc
    | l ->
        let i = String.index l ':' in
        fields
          (( String.lowercase_ascii (String.sub l 0 i),
             String.trim (String.sub l (i + 1) (String.length l - i - 1)) )
          :: acc)
  in
  let headers = fields [] in
  let body =
    if head || status < 200 || status = 204 || status = 304 then ""
    else
      match
        ( List.assoc_opt "content-length" headers,
          List.assoc_opt "transfer-encoding" headers )
      with
      | Some n, _ -> Eio.Buf_read.take (int_of_string n) r
      | None, Some _ ->
          let b = Buffer.create 64 in
          let rec chunks () =
            match int_of_string ("0x" ^ Eio.Buf_read.line r) with
            | 0 -> ignore (Eio.Buf_read.line r : string)
            | n ->
                Buffer.add_string b (Eio.Buf_read.take n r);
                ignore (Eio.Buf_read.line r : string);
                chunks ()
          in
          chunks ();
          Buffer.contents b
      (* RFC 9112 §6.3: neither length nor coding is a body that ends
         where the connection does. *)
      | None, None -> Eio.Buf_read.take_all r
  in
  { status; headers; body }

let at_end r =
  match Eio.Buf_read.ensure r 1 with
  | () -> false
  | exception End_of_file -> true
  | exception Eio.Io (Eio.Net.E (Connection_reset _), _) -> true

(* One connection, the bytes sent in the pieces [delivery] makes, and
   every read [In_memory.at_once], so a server that waits where it should
   not fails the row rather than answering when its own limit passes. *)
let converse env connect delivery bytes f =
  Eio.Switch.run @@ fun sw ->
  let flow = connect ~sw in
  let r =
    Eio.Buf_read.of_flow ~max_size:1_000_000
      (In_memory.at_once ~clock:(Eio.Stdenv.mono_clock env) flow)
  in
  (* A server that has answered and closed takes no more: what is left of
     the bytes has nobody to go to, which is the row's point. *)
  let send p =
    try Eio.Flow.copy_string p flow
    with Eio.Io (Eio.Net.E (Connection_reset _), _) -> ()
  in
  Eio.Fiber.both
    (fun () -> List.iter send (split delivery bytes))
    (fun () -> f r)

(* ------------------------------------------------------------------ *)
(* The rows *)

type header =
  | Is of string
  | Only of string  (** once, and nowhere else in the head *)
  | Once  (** exactly once, whatever it says *)
  | Present
  | Absent

(* Whether the values a head gave one field are what a row owes it. *)
let holds owed values =
  match (owed, values) with
  | (Is s | Only s), [ v ] -> String.equal s v
  | Is s, v :: _ -> String.equal s v
  | Once, [ _ ] | Present, _ :: _ | Absent, [] -> true
  | (Only _ | Once), _ :: _ :: _
  | (Is _ | Only _ | Once | Present), []
  | Absent, _ :: _ ->
      false

let shown = function [] -> "absent" | vs -> String.concat " | " vs

type answer = {
  status : int;
  body : string option;
  headers : (string * header) list;
  to_head : bool;  (** an answer to HEAD, so no body follows it *)
}

let answer ?body ?(headers = []) ?(to_head = false) status =
  { status; body; headers; to_head }

(* What a connection comes to once its answers are read: closed, or still
   open, which the row proves by asking it one more thing. *)
type ending = Closed | Open

type owes =
  | Parsed of {
      meth : string;
      target : string;
      version : Head.version;
      headers : (string * string) list;
      host : string option;
      body : string;
    }
  | Refused of int  (** the head is refused with this status *)
  | Unframed_as of int  (** the head reads; its framing is refused *)
  | Body_broken  (** the head reads; its body cannot be *)
  | Body_too_large  (** the head reads; its body is past the limit *)
  | Answers of answer list * ending
      (** the whole server's answers, and what the connection came to *)

type row = { rfc : string; says : string; bytes : string; owes : owes }

let row rfc says bytes owes = { rfc; says; bytes; owes }

let request ?(line = "GET / HTTP/1.1") ?(body = "") fields =
  line ^ "\r\n"
  ^ String.concat "" (List.map (fun f -> f ^ "\r\n") fields)
  ^ "\r\n" ^ body

let get path = request ~line:("GET " ^ path ^ " HTTP/1.1") [ "Host: t" ]

let post ?(fields = []) path body =
  request
    ~line:("POST " ^ path ^ " HTTP/1.1")
    ([ "Host: t"; Printf.sprintf "Content-Length: %d" (String.length body) ]
    @ fields)
    ~body

let chunked path body =
  request
    ~line:("POST " ^ path ^ " HTTP/1.1")
    [ "Host: t"; "Transfer-Encoding: chunked" ]
    ~body

let parsed ?(meth = "GET") ?(target = "/") ?(version = Head.Http_1_1)
    ?(host = Some "t") ?(body = "") headers =
  Parsed { meth; target; version; headers; host; body }

(* A request that the server must never see as one: what a body left on
   the connection would be read as. *)
let smuggled = get "/id/smuggled"

let heads =
  [
    row "9112 §5" "fields are read in order, names as sent, values trimmed"
      (request [ "Host: t"; "X-A:  one  "; "x-a:\ttwo" ])
      (parsed [ ("Host", "t"); ("X-A", "one"); ("x-a", "two") ]);
    row "9112 §2.2" "empty lines before the request line are ignored"
      ("\r\n\r\n" ^ request [ "Host: t" ])
      (parsed [ ("Host", "t") ]);
    row "9112 §2.2" "a line may end in a bare LF" "GET / HTTP/1.1\nHost: t\n\n"
      (parsed [ ("Host", "t") ]);
    row "9112 §2.2" "a bare CR in a field is refused"
      (request [ "Host: t"; "X-A: a\rb" ])
      (Refused 400);
    row "9112 §2.2" "a bare CR in the request line is refused"
      (request ~line:"GET /a\rb HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "9112 §5.1" "whitespace before a field's colon is 400"
      (request [ "Host : t" ]) (Refused 400);
    row "9112 §5.2" "a line folded onto the one before it is refused"
      (request [ "Host: t"; "X-A: 1"; " 2" ])
      (Refused 400);
    row "9110 §5.1" "a field name that is not a token is 400"
      (request [ "Host: t"; "X(A): 1" ])
      (Refused 400);
    row "9110 §5.5" "a NUL in a field value is refused"
      (request [ "Host: t"; "X-A: a\000b" ])
      (Refused 400);
    row "9110 §5.5" "a control character in a field value is refused"
      (request [ "Host: t"; "X-A: a\001b" ])
      (Refused 400);
    row "9110 §5.5" "DEL in a field value is refused"
      (request [ "Host: t"; "X-A: a\127b" ])
      (Refused 400);
    row "9110 §5.4" "a field section past the limit is 431"
      (request [ "Host: t"; "X-Big: " ^ String.make 2000 'x' ])
      (Refused 431);
    row "9112 §3" "a method that is not a token is 400"
      (request ~line:"GE(T / HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "9112 §3" "a request line of two words is 400"
      (request ~line:"GET /" [ "Host: t" ])
      (Refused 400);
    row "9112 §3" "two spaces in the request line is 400"
      (request ~line:"GET  / HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "9112 §2.3" "a version that is not HTTP/1.x is 505"
      (request ~line:"GET / HTTP/2.0" [ "Host: t" ])
      (Refused 505);
    row "9112 §2.3" "a version spelled some other way is 400"
      (request ~line:"GET / http/1.1" [ "Host: t" ])
      (Refused 400);
    row "9110 §6.2" "a later HTTP/1 minor version is read as HTTP/1.1"
      (request ~line:"GET / HTTP/1.2" [ "Host: t" ])
      (parsed [ ("Host", "t") ]);
    row "9112 §3" "a request line past the limit is 414"
      (request
         ~line:("GET /" ^ String.make 2000 'a' ^ " HTTP/1.1")
         [ "Host: t" ])
      (Refused 414);
    row "9112 §3.2" "an HTTP/1.1 request with no Host is 400"
      (request [ "X-A: 1" ]) (Refused 400);
    row "9112 §3.2" "a request with two Hosts is 400"
      (request [ "Host: t"; "Host: t" ])
      (Refused 400);
    row "9112 §3.2" "an HTTP/1.0 request with two Hosts is 400"
      (request ~line:"GET / HTTP/1.0" [ "Host: t"; "Host: u" ])
      (Refused 400);
    row "9112 §3.2" "a Host that is not a host is 400"
      (request [ "Host: exa mple" ])
      (Refused 400);
    row "9112 §3.2" "a Host with userinfo is 400"
      (request [ "Host: kim@t" ])
      (Refused 400);
    row "9112 §3.2" "a Host with a port, and one in brackets, are hosts"
      (request [ "Host: [::1]:8443" ])
      (parsed ~host:(Some "[::1]:8443") [ ("Host", "[::1]:8443") ]);
    row "9112 §3.2" "an empty Host names no host" (request [ "Host:" ])
      (parsed ~host:None [ ("Host", "") ]);
    row "9112 §3.2" "an HTTP/1.0 request with no Host is read"
      (request ~line:"GET / HTTP/1.0" [])
      (parsed ~version:Head.Http_1_0 ~host:None []);
    row "9112 §3.2.2"
      "an absolute-form target's authority is the host, not Host"
      (request ~line:"GET http://abs.example:8080/x?y HTTP/1.1" [ "Host: t" ])
      (parsed ~target:"http://abs.example:8080/x?y"
         ~host:(Some "abs.example:8080")
         [ ("Host", "t") ]);
    row "9112 §3.2.2" "an HTTP/1.1 absolute-form request with no Host is 400"
      (request ~line:"GET http://abs.example/x HTTP/1.1" [])
      (Refused 400);
    row "9110 §4.2.4" "an absolute-form target with userinfo is 400"
      (request ~line:"GET http://kim@abs.example/ HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "9110 §4.2.1" "an http target with no host is 400"
      (request ~line:"GET http:///x HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "9112 §3.2.4" "an asterisk is a server-wide OPTIONS'"
      (request ~line:"OPTIONS * HTTP/1.1" [ "Host: t" ])
      (parsed ~meth:"OPTIONS" ~target:"*" [ ("Host", "t") ]);
    row "9112 §3.2.4" "an asterisk is no other method's"
      (request ~line:"GET * HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "9112 §3.2.3" "CONNECT's target is host:port, and the host"
      (request ~line:"CONNECT abs.example:443 HTTP/1.1" [ "Host: t" ])
      (parsed ~meth:"CONNECT" ~target:"abs.example:443"
         ~host:(Some "abs.example:443")
         [ ("Host", "t") ]);
    row "9112 §3.2.3" "CONNECT's target is nothing else"
      (request ~line:"CONNECT /x HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "9112 §3.2.3" "CONNECT's target needs its port"
      (request ~line:"CONNECT abs.example: HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "9112 §3.2.3" "CONNECT's target needs its host"
      (request ~line:"CONNECT :443 HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "9112 §3.2.3" "CONNECT to an IPv6 address and a port"
      (request ~line:"CONNECT [::1]:443 HTTP/1.1" [ "Host: t" ])
      (parsed ~meth:"CONNECT" ~target:"[::1]:443" ~host:(Some "[::1]:443")
         [ ("Host", "t") ]);
    row "9112 §3.2.3" "CONNECT to an IP literal with no port is refused"
      (request ~line:"CONNECT [::1] HTTP/1.1" [ "Host: t" ])
      (Refused 400);
    row "RFC 3986 §3.2.2" "an IP literal that is no address is 400"
      (request [ "Host: [zz]" ]) (Refused 400);
    row "RFC 3986 §3.2.2" "an IPv6 address with two :: is 400"
      (request [ "Host: [1::2::3]" ])
      (Refused 400);
    row "RFC 3986 §3.2.2" "an IPv6 address of nine groups is 400"
      (request [ "Host: [1:2:3:4:5:6:7:8:9]" ])
      (Refused 400);
    row "RFC 3986 §3.2.2" "an IPv6 address of eight groups is a host"
      (request [ "Host: [1:2:3:4:5:6:7:8]" ])
      (parsed ~host:(Some "[1:2:3:4:5:6:7:8]")
         [ ("Host", "[1:2:3:4:5:6:7:8]") ]);
    row "RFC 3986 §3.2.2" "an IPv4 address may end an IPv6 one"
      (request [ "Host: [::ffff:192.0.2.1]" ])
      (parsed ~host:(Some "[::ffff:192.0.2.1]")
         [ ("Host", "[::ffff:192.0.2.1]") ]);
    row "RFC 3986 §3.2.2" "an IPv4 part past 255 is 400"
      (request [ "Host: [::ffff:256.0.2.1]" ])
      (Refused 400);
    row "RFC 3986 §3.2.2" "an IPvFuture is a host"
      (request [ "Host: [v1.fe80::a+en1]" ])
      (parsed ~host:(Some "[v1.fe80::a+en1]") [ ("Host", "[v1.fe80::a+en1]") ]);
  ]

let bodies =
  [
    row "9112 §6.3" "a request with no framing has no body"
      (request [ "Host: t" ])
      (parsed [ ("Host", "t") ]);
    row "9112 §6.3" "a Content-Length is read to its end"
      (request ~line:"POST / HTTP/1.1" ~body:"hello"
         [ "Host: t"; "Content-Length: 5" ])
      (parsed ~meth:"POST" ~body:"hello"
         [ ("Host", "t"); ("Content-Length", "5") ]);
    row "9112 §6.3" "identical repeated lengths are one length"
      (request ~line:"POST / HTTP/1.1" ~body:"hello"
         [ "Host: t"; "Content-Length: 5"; "Content-Length: 5" ])
      (parsed ~meth:"POST" ~body:"hello"
         [ ("Host", "t"); ("Content-Length", "5"); ("Content-Length", "5") ]);
    row "9112 §6.3" "a list of identical lengths is one length"
      (request ~line:"POST / HTTP/1.1" ~body:"hello"
         [ "Host: t"; "Content-Length: 5, 5" ])
      (parsed ~meth:"POST" ~body:"hello"
         [ ("Host", "t"); ("Content-Length", "5, 5") ]);
    row "9110 §5.6.1" "an empty element in a list of lengths is no length"
      (request ~line:"POST / HTTP/1.1" ~body:"hello"
         [ "Host: t"; "Content-Length: 5, , 5" ])
      (parsed ~meth:"POST" ~body:"hello"
         [ ("Host", "t"); ("Content-Length", "5, , 5") ]);
    row "9112 §6.3" "a Content-Length that is not a number is 400"
      (request [ "Host: t"; "Content-Length: -5" ])
      (Unframed_as 400);
    row "9112 §6.3" "two different lengths are 400"
      (request [ "Host: t"; "Content-Length: 5"; "Content-Length: 6" ])
      (Unframed_as 400);
    row "9112 §6.3" "a list of different lengths is 400"
      (request [ "Host: t"; "Content-Length: 5, 6" ])
      (Unframed_as 400);
    row "9112 §6.3" "a length past any int is 400"
      (request [ "Host: t"; "Content-Length: 99999999999999999999" ])
      (Unframed_as 400);
    row "9112 §6.1" "Transfer-Encoding beside Content-Length is refused"
      (request [ "Host: t"; "Transfer-Encoding: chunked"; "Content-Length: 5" ])
      (Unframed_as 400);
    row "9112 §6.3" "a Transfer-Encoding not ending in chunked is 400"
      (request [ "Host: t"; "Transfer-Encoding: gzip" ])
      (Unframed_as 400);
    row "9112 §6.1" "a coding under chunked this server does not decode is 501"
      (request [ "Host: t"; "Transfer-Encoding: gzip, chunked" ])
      (Unframed_as 501);
    row "9112 §7" "chunked takes no parameters"
      (request [ "Host: t"; "Transfer-Encoding: chunked;q=1" ])
      (Unframed_as 400);
    row "9112 §7.1" "a chunked body is read to its last chunk"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhello\r\n1\r\n!\r\n0\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      (parsed ~meth:"POST" ~body:"hello!"
         [ ("Host", "t"); ("Transfer-Encoding", "chunked") ]);
    row "9112 §7.1.1" "an unknown chunk extension is ignored"
      (request ~line:"POST / HTTP/1.1" ~body:"5;ext=\"1\"\r\nhello\r\n0\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      (parsed ~meth:"POST" ~body:"hello"
         [ ("Host", "t"); ("Transfer-Encoding", "chunked") ]);
    row "9112 §7.1.2" "a trailer is read and left out of the body"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhello\r\n0\r\nX-T: 1\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      (parsed ~meth:"POST" ~body:"hello"
         [ ("Host", "t"); ("Transfer-Encoding", "chunked") ]);
    row "9112 §7.1" "a chunk size past what an int holds is refused"
      (request ~line:"POST / HTTP/1.1"
         ~body:"ffffffffffffffffff\r\nx\r\n0\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §7.1" "a chunk size that is not hex is refused"
      (request ~line:"POST / HTTP/1.1" ~body:"zz\r\nhello\r\n0\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §7.1" "a chunk not followed by CRLF is refused"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhelloXX\r\n0\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §8" "a body cut short is refused"
      (request ~line:"POST / HTTP/1.1" ~body:"hel"
         [ "Host: t"; "Content-Length: 10" ])
      Body_broken;
    row "9112 §8" "a chunked body cut short is refused"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhel"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9110 §5.6.1.2" "an empty list element is nothing: chunked, is chunked"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhello\r\n0\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: , chunked," ])
      (parsed ~meth:"POST" ~body:"hello"
         [ ("Host", "t"); ("Transfer-Encoding", ", chunked,") ]);
    row "9112 §6.1" "chunked applied twice is 400"
      (request [ "Host: t"; "Transfer-Encoding: chunked, chunked" ])
      (Unframed_as 400);
    row "9112 §6.1" "chunked applied twice, in two fields, is 400"
      (request
         [
           "Host: t"; "Transfer-Encoding: chunked"; "Transfer-Encoding: chunked";
         ])
      (Unframed_as 400);
    row "9112 §7.1" "a chunk-size line ending in a bare LF is refused"
      (request ~line:"POST / HTTP/1.1" ~body:"5\nhello\r\n0\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §7.1" "the last chunk's line ending in a bare LF is refused"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhello\r\n0\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §7.1" "a chunk ending in a bare LF is refused"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhello\n0\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §7.1.2" "a trailer line ending in a bare LF is refused"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhello\r\n0\r\nX-T: 1\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §7.1.2"
      "the empty line after a trailer ending in a bare LF is refused"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhello\r\n0\r\n\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §7.1.1" "a chunk's extensions count toward the body's limit"
      (request ~line:"POST / HTTP/1.1"
         ~body:
           (String.concat ""
              (List.init 6 (fun _ ->
                   "1;x=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\r\n\
                    a\r\n"))
           ^ "0\r\n\r\n")
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_too_large;
    row "9112 §7.1.2" "a trailer line with no colon breaks the body"
      (request ~line:"POST / HTTP/1.1" ~body:"5\r\nhello\r\n0\r\nX-T\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §7.1.2" "a folded trailer line breaks the body"
      (request ~line:"POST / HTTP/1.1"
         ~body:"5\r\nhello\r\n0\r\nX-T: 1\r\n 2\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
    row "9112 §7.1.2" "a trailer name that is not a token breaks the body"
      (request ~line:"POST / HTTP/1.1"
         ~body:"5\r\nhello\r\n0\r\nX(T): 1\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked" ])
      Body_broken;
  ]

let refused_and_closed rfc says bytes status =
  row rfc says (bytes ^ smuggled) (Answers ([ answer status ], Closed))

let server =
  [
    refused_and_closed "9112 §3" "an invalid request line is 400 and closed"
      "GET /id/a\r\nHost: t\r\n\r\n" 400;
    refused_and_closed "9112 §5.2" "a folded line is 400 and closed"
      (request [ "Host: t"; "X-A: 1"; " 2" ])
      400;
    refused_and_closed "9112 §6.3" "an invalid length is 400 and closed"
      (request ~line:"POST /read/a HTTP/1.1"
         [ "Host: t"; "Content-Length: -5" ])
      400;
    refused_and_closed "9112 §6.3"
      "a Transfer-Encoding not ending in chunked is 400 and closed"
      (request ~line:"POST /read/a HTTP/1.1"
         [ "Host: t"; "Transfer-Encoding: gzip" ])
      400;
    refused_and_closed "9112 §6.1" "an unknown coding is 501 and closed"
      (request ~line:"POST /read/a HTTP/1.1"
         [ "Host: t"; "Transfer-Encoding: gzip, chunked" ])
      501;
    refused_and_closed "9112 §6.1" "both framings are 400 and closed"
      (request ~line:"POST /read/a HTTP/1.1" ~body:"0\r\n\r\n"
         [ "Host: t"; "Transfer-Encoding: chunked"; "Content-Length: 5" ])
      400;
    refused_and_closed "9110 §5.4" "a field section past the limit is 431"
      (request [ "Host: t"; "X-Big: " ^ String.make 2000 'x' ])
      431;
    row "9112 §9.3" "a body nobody read is never the next request"
      (post "/ignore/a" smuggled ^ get "/id/b")
      (Answers ([ answer ~body:"a" 200; answer ~body:"b" 200 ], Open));
    row "9112 §9.3" "a chunked body nobody read is never the next request"
      (chunked "/ignore/a"
         (Printf.sprintf "%x\r\n%s\r\n0\r\n\r\n" (String.length smuggled)
            smuggled)
      ^ get "/id/b")
      (Answers ([ answer ~body:"a" 200; answer ~body:"b" 200 ], Open));
    row "9112 §9.3" "a broken body closes the connection"
      (chunked "/read/a" "5\r\nhelloXX\r\n0\r\n\r\n" ^ smuggled)
      (Answers ([ answer 400 ], Closed));
    row "9112 §9.3" "a body too large to read is followed by the next request"
      (post "/read/a" (String.make 100 'x') ^ get "/id/b")
      (Answers ([ answer 413; answer ~body:"b" 200 ], Open));
    row "9112 §9.3.2" "pipelined requests are answered in order"
      (get "/id/a" ^ post "/read/b" "body" ^ get "/id/c")
      (Answers
         ( [
             answer ~body:"a" 200;
             answer ~body:"b=body" 200;
             answer ~body:"c" 200;
           ],
           Open ));
    row "9112 §9.6" "a client's close is honoured"
      (request ~line:"GET /id/a HTTP/1.1" [ "Host: t"; "Connection: close" ]
      ^ smuggled)
      (Answers
         ( [ answer ~body:"a" ~headers:[ ("connection", Is "close") ] 200 ],
           Closed ));
    row "9112 §9.6" "a server's close is honoured"
      (get "/close" ^ smuggled)
      (Answers
         ( [ answer ~body:"bye" ~headers:[ ("connection", Only "close") ] 200 ],
           Closed ));
    row "9112 §9.3" "HTTP/1.0 is closed after its answer"
      (request ~line:"GET /id/a HTTP/1.0" [] ^ smuggled)
      (Answers ([ answer ~body:"a" 200 ], Closed));
    row "9112 §9.3" "HTTP/1.0 that asks to keep the connection keeps it"
      (request ~line:"GET /id/a HTTP/1.0" [ "Connection: keep-alive" ])
      (Answers
         ( [ answer ~body:"a" ~headers:[ ("connection", Is "keep-alive") ] 200 ],
           Open ));
    row "9112 §9.3" "HTTP/1.0 that says close beside keep-alive is closed"
      (request ~line:"GET /id/a HTTP/1.0" [ "Connection: keep-alive, close" ]
      ^ smuggled)
      (Answers
         ( [ answer ~body:"a" ~headers:[ ("connection", Only "close") ] 200 ],
           Closed ));
    row "9112 §9.3" "and so it is when they are two fields"
      (request ~line:"GET /id/a HTTP/1.0"
         [ "Connection: keep-alive"; "Connection: close" ]
      ^ smuggled)
      (Answers
         ( [ answer ~body:"a" ~headers:[ ("connection", Only "close") ] 200 ],
           Closed ));
    row "9112 §6.1" "a 204 carries neither length nor coding" (get "/nothing")
      (Answers
         ( [
             answer
               ~headers:
                 [ ("content-length", Absent); ("transfer-encoding", Absent) ]
               204;
           ],
           Open ));
    row "9110 §15.2" "a 100 Continue carries no length"
      (post ~fields:[ "Expect: 100-continue" ] "/read/a" "hello")
      (Answers
         ( [
             answer ~headers:[ ("content-length", Absent) ] 100;
             answer ~body:"a=hello" 200;
           ],
           Open ));
    row "9110 §9.3.2" "HEAD answers GET's length and no content"
      (request ~line:"HEAD /id/abc HTTP/1.1" [ "Host: t" ])
      (Answers
         ( [ answer ~to_head:true ~headers:[ ("content-length", Is "3") ] 200 ],
           Open ));
    row "9110 §15.5.6" "a 405 says what is allowed" (get "/read/a")
      (Answers ([ answer ~headers:[ ("allow", Present) ] 405 ], Open));
    row "9112 §7.1.2" "a trailer is never merged into the head"
      (chunked "/x-id" "5\r\nhello\r\n0\r\nX-Id: merged\r\n\r\n")
      (Answers ([ answer ~body:"none" 200 ], Open));
    refused_and_closed "9112 §3.2"
      "an HTTP/1.1 request with no Host is 400 and closed"
      "GET /id/a HTTP/1.1\r\n\r\n" 400;
    refused_and_closed "9112 §3"
      "a request line past the limit is 414 and closed"
      (get ("/id/" ^ String.make 2000 'a'))
      414;
    row "9110 §6.6.1" "every 2xx, 3xx and 4xx is dated"
      (get "/id/a" ^ get "/nothing" ^ get "/away" ^ get "/nope" ^ get "/read/a")
      (Answers
         ( List.map
             (fun status ->
               answer ~headers:[ ("date", Is example_date) ] status)
             [ 200; 204; 302; 404; 405 ],
           Open ));
    row "9110 §6.6.1" "a head refused before it could be read is dated too"
      ("GET /id/a\r\n\r\n" ^ smuggled)
      (Answers ([ answer ~headers:[ ("date", Is example_date) ] 400 ], Closed));
    row "9112 §6.1" "a stream to HTTP/1.1 is chunked" (get "/stream")
      (Answers
         ( [
             answer ~body:"ab"
               ~headers:[ ("transfer-encoding", Is "chunked") ]
               200;
           ],
           Open ));
    row "9112 §6.1"
      "a stream to HTTP/1.0 has no Transfer-Encoding, and ends with the \
       connection"
      (request ~line:"GET /stream HTTP/1.0" [ "Connection: keep-alive" ])
      (Answers
         ( [
             answer ~body:"ab"
               ~headers:
                 [ ("transfer-encoding", Absent); ("connection", Is "close") ]
               200;
           ],
           Closed ));
    row "9112 §6.1"
      "an HTTP/1.0 request with Transfer-Encoding is answered, then closed"
      (request ~line:"POST /read/a HTTP/1.0" ~body:"5\r\nhello\r\n0\r\n\r\n"
         [ "Connection: keep-alive"; "Transfer-Encoding: chunked" ]
      ^ smuggled)
      (Answers ([ answer ~body:"a=hello" 200 ], Closed));
    row "9110 §10.1.1" "a body too large is refused, never asked for"
      (request ~line:"POST /read/a HTTP/1.1"
         [ "Host: t"; "Content-Length: 100"; "Expect: 100-continue" ])
      (Answers ([ answer 413 ], Closed));
    row "9110 §10.1.1" "a request with no body is not closed for its Expect"
      (request ~line:"GET /id/a HTTP/1.1" [ "Host: t"; "Expect: 100-continue" ])
      (Answers ([ answer ~body:"a" 200 ], Open));
    row "9110 §10.1.1" "HTTP/1.0 is sent no 100 Continue"
      (request ~line:"POST /read/a HTTP/1.0" ~body:"hello"
         [ "Content-Length: 5"; "Expect: 100-continue" ])
      (Answers ([ answer ~body:"a=hello" 200 ], Closed));
    row "9110 §7.8" "a 101 names the protocol the client offered"
      (request ~line:"GET /upgrade HTTP/1.1"
         [
           "Host: t"; "Connection: keep-alive, Upgrade"; "Upgrade: other, echo";
         ])
      (Answers
         ( [
             answer
               ~headers:[ ("upgrade", Is "echo"); ("connection", Is "upgrade") ]
               101;
           ],
           Closed ));
    row "9110 §7.8" "a takeover the client did not offer is the route's bug"
      (get "/upgrade")
      (Answers ([ answer ~headers:[ ("upgrade", Absent) ] 500 ], Open));
    row "9110 §7.8" "an Upgrade without Connection: upgrade offers nothing"
      (request ~line:"GET /upgrade HTTP/1.1" [ "Host: t"; "Upgrade: echo" ])
      (Answers ([ answer 500 ], Open));
    row "9110 §7.8" "an HTTP/1.0 client is never switched"
      (request ~line:"GET /upgrade HTTP/1.0"
         [ "Connection: upgrade"; "Upgrade: echo" ])
      (Answers ([ answer 500 ], Closed));
    row "9110 §9.1" "a method nothing here implements is 501"
      (request ~line:"PROPFIND /id/a HTTP/1.1" [ "Host: t" ])
      (Answers ([ answer 501 ], Open));
    row "9110 §15.5.2" "a 401 says how to authenticate" (get "/private")
      (Answers
         ( [
             answer ~headers:[ ("www-authenticate", Is {|Test realm="t"|}) ] 401;
           ],
           Open ));
    row "9112 §3.2" "Host names the request's host" (get "/host")
      (Answers ([ answer ~body:"t" 200 ], Open));
    row "9112 §3.2.2" "an absolute-form target names it instead"
      (request ~line:"GET http://abs.example/host HTTP/1.1" [ "Host: t" ])
      (Answers ([ answer ~body:"abs.example" 200 ], Open));
    row "9112 §9.6" "a close with a body still arriving is answered first"
      (post "/ignore/a" (String.make 1500 'x'))
      (Answers
         ( [ answer ~body:"a" ~headers:[ ("connection", Is "close") ] 200 ],
           Closed ));
    row "9112 §9.6" "a 413 reaches the client before the close"
      (post "/read/a" (String.make 1500 'x'))
      (Answers ([ answer 413 ], Closed));
    row "9112 §7.1" "a chunk-size line ending in a bare LF is 400 and closed"
      (chunked "/read/a" "5\nhello\r\n0\r\n\r\n" ^ smuggled)
      (Answers ([ answer 400 ], Closed));
  ]

(* What the server writes for a handler: every field that frames an answer
   or governs its connection is the server's, and a handler that writes one
   -- or answers a status that is no final answer -- is the route's bug,
   answered 500 with the server's own framing and nothing of its. Each is
   owed its 500 on a connection that still reads the next request right,
   which is what a second length would break. *)
let route's_bug rfc says path =
  row rfc says (get path)
    (Answers
       ( [
           answer
             ~headers:
               [ ("content-length", Once); ("transfer-encoding", Absent) ]
             500;
         ],
         Open ))

let writing =
  List.map
    (fun (rfc, field) ->
      route's_bug rfc
        (Printf.sprintf "a handler's %s is the route's bug" field)
        ("/sets/" ^ field))
    [
      ("9112 §6.2", "content-length");
      ("9112 §6.2", "Content-Length");
      ("9112 §6.1", "transfer-encoding");
      ("9112 §9.6", "connection");
      ("9112 §9.6", "keep-alive");
      ("9110 §7.8", "upgrade");
      ("9110 §10.1.4", "te");
      ("9110 §6.6.2", "trailer");
    ]
  @ [
      route's_bug "9112 §6.3" "a stream given a length is the route's bug"
        "/stream-length";
      route's_bug "9110 §15" "a status past 599 is the route's bug"
        "/status/1000";
      route's_bug "9110 §15.2" "a 1xx as the answer is the route's bug"
        "/status/103";
      route's_bug "9110 §15.2"
        "a 101 anywhere but a takeover is the route's bug" "/status/101";
      row "9110 §15" "any final status is written as it is" (get "/status/299")
        (Answers ([ answer ~body:"hello" 299 ], Open));
      row "9112 §9.3" "a kept HTTP/1.1 answer says nothing of its connection"
        (get "/id/a")
        (Answers
           ([ answer ~body:"a" ~headers:[ ("connection", Absent) ] 200 ], Open));
      row "9112 §9.6" "an answer that asks for a close gets one, said once"
        (request ~line:"GET /close HTTP/1.0" [ "Connection: keep-alive" ]
        ^ smuggled)
        (Answers
           ( [ answer ~body:"bye" ~headers:[ ("connection", Only "close") ] 200 ],
             Closed ));
      row "9112 §9.6" "a client's close beside the answer's is said once"
        (request ~line:"GET /close HTTP/1.1" [ "Host: t"; "Connection: close" ]
        ^ smuggled)
        (Answers
           ( [ answer ~body:"bye" ~headers:[ ("connection", Only "close") ] 200 ],
             Closed ));
      row "9110 §7.8" "a takeover answered to HEAD is its head, then closed"
        (request ~line:"HEAD /upgrade HTTP/1.1"
           [ "Host: t"; "Connection: upgrade"; "Upgrade: echo" ]
        ^ smuggled)
        (Answers
           ( [
               answer ~to_head:true
                 ~headers:
                   [ ("upgrade", Only "echo"); ("connection", Only "upgrade") ]
                 101;
             ],
             Closed ));
    ]

(* The published request-smuggling classics (RFC 9112 §11.2): each hides a
   request where a reader that frames the body another way would find one.
   Each is owed a refusal and the connection closed, or one answer and no
   other -- never the hidden request answered. *)
let smuggling = "0\r\n\r\n" ^ smuggled

let attack says fields owes =
  row "9112 §11.2" says
    (request ~line:"POST /read/a HTTP/1.1" ~body:smuggling ("Host: t" :: fields))
    owes

let length = Printf.sprintf "Content-Length: %d" (String.length smuggling)
let refused status = Answers ([ answer status ], Closed)

(* The body read as its length says, the hidden request in it. *)
let one_request = Answers ([ answer ~body:("a=" ^ smuggling) 200 ], Open)

let attacks =
  List.map
    (fun (says, te) -> attack ("CL.TE, " ^ says) [ length; te ] (refused 400))
    [
      ("plain", "Transfer-Encoding: chunked");
      ("a leading space", "Transfer-Encoding:  chunked");
      ("a trailing tab", "Transfer-Encoding: chunked\t");
      ("a different case", "Transfer-Encoding: CHUNKED");
      ("a lower-case name", "transfer-encoding: chunked");
      ("xchunked", "Transfer-Encoding: xchunked");
      ("chunked, identity", "Transfer-Encoding: chunked, identity");
      ("a quoted value", "Transfer-Encoding: \"chunked\"");
      ("a vertical tab", "Transfer-Encoding:\011chunked");
      ("a space before the colon", "Transfer-Encoding : chunked");
      ("a line feed before the value", "Transfer-Encoding:\nchunked");
      ("folded onto the line before", "X-A: 1\r\n Transfer-Encoding: chunked");
      ("a line feed hiding a field", "X-A: 1\nTransfer-Encoding: chunked");
      ("an empty element", "Transfer-Encoding: chunked,");
    ]
  @ List.map
      (fun (says, te) -> attack ("TE.CL, " ^ says) [ te; length ] (refused 400))
      [
        ("plain", "Transfer-Encoding: chunked");
        ( "a duplicate field",
          "Transfer-Encoding: chunked\r\nTransfer-Encoding: x" );
      ]
  @ [
      attack "a name that is not Transfer-Encoding is not one"
        [ length; "Transfer_Encoding: chunked" ]
        one_request;
      attack "TE.TE, chunked then identity"
        [ "Transfer-Encoding: chunked"; "Transfer-Encoding: identity" ]
        (refused 400);
      attack "TE.TE, identity then chunked"
        [ "Transfer-Encoding: identity"; "Transfer-Encoding: chunked" ]
        (refused 501);
      attack "TE.TE, chunked twice"
        [ "Transfer-Encoding: chunked"; "Transfer-Encoding: chunked" ]
        (refused 400);
      attack "a length with a plus" [ "Content-Length: +43" ] (refused 400);
      attack "a length with leading zeros is the length"
        [ Printf.sprintf "Content-Length: 000%d" (String.length smuggling) ]
        one_request;
      attack "a length in hex" [ "Content-Length: 0x2b" ] (refused 400);
      attack "a length with a space in it" [ "Content-Length: 4 3" ]
        (refused 400);
      attack "two lengths" [ length; "Content-Length: 44" ] (refused 400);
      attack "a length past any int"
        [ "Content-Length: 99999999999999999999" ]
        (refused 400);
      row "9112 §11.2" "a chunk size past any int"
        (chunked "/read/a" ("ffffffffffffffffff1\r\n" ^ smuggling))
        (refused 400);
      row "9112 §11.2" "a chunk size with leading zeros is the size"
        (chunked "/read/a" "0005\r\nhello\r\n0\r\n\r\n" ^ smuggled)
        (Answers
           ([ answer ~body:"a=hello" 200; answer ~body:"smuggled" 200 ], Open));
      (* The 2025 desyncs, which turn on Expect and on answering early. *)
      attack "an obfuscated Expect is no expectation, and the length is read"
        [ length; "Expect: y 100-continue" ]
        one_request;
      row "9112 §11.2"
        "an Expect whose body comes unasked is answered and closed, never read \
         as a request"
        (request ~line:"POST /ignore/a HTTP/1.1" ~body:smuggling
           [ "Host: t"; length; "Expect: 100-continue" ])
        (Answers ([ answer ~body:"a" 200 ], Closed));
      row "9112 §11.2"
        "0.CL: a body past the discard limit is answered early only on a \
         closing connection"
        (post "/ignore/a"
           (String.make (discard_on_the_server + 1) 'x' ^ smuggled))
        (Answers
           ( [ answer ~body:"a" ~headers:[ ("connection", Only "close") ] 200 ],
             Closed ));
    ]

(* A response, as a client reads it: owed to the request it answers. *)
type response_owes =
  | Response_is of {
      version : Head.version;
      status : int;
      reason : string;
      headers : (string * string) list;
      body : string;
      kept : bool;  (** whether the connection may carry another *)
    }
  | Malformed  (** the head is not one *)
  | Closed_first  (** the server went before a byte of a head *)
  | Unframed  (** the head reads; its framing is refused *)
  | Cut_short  (** the head reads; its body cannot be *)

type response_row = {
  rfc : string;
  says : string;
  meth : Meth.t;  (** the request's, which decides whether a body follows *)
  bytes : string;
  owes : response_owes;
}

let rrow ?(meth = `GET) rfc says bytes owes = { rfc; says; meth; bytes; owes }

let response ?(version = Head.Http_1_1) ?(reason = "OK") ?(kept = true)
    ?(body = "") status headers =
  Response_is { version; status; reason; headers; body; kept }

let status_line ?(version = "HTTP/1.1") ?(reason = "OK") status fields body =
  Printf.sprintf "%s %d %s\r\n%s\r\n%s" version status reason
    (String.concat "" (List.map (fun f -> f ^ "\r\n") fields))
    body

let ok_fields = [ "Content-Length: 5" ]
let ok_headers = [ ("Content-Length", "5") ]
let chunked_hello = "5\r\nhello\r\n0\r\n\r\n"
let te = [ ("Transfer-Encoding", "chunked") ]

let responses =
  [
    rrow "9112 §4" "a status line, fields, and a body of its length"
      (status_line 200 [ "X-A:  one "; "Content-Length: 5" ] "hello")
      (response ~body:"hello" 200 [ ("X-A", "one"); ("Content-Length", "5") ]);
    rrow "9112 §4" "a reason may be empty, after its space"
      "HTTP/1.1 599 \r\nContent-Length: 0\r\n\r\n"
      (response ~reason:"" 599 [ ("Content-Length", "0") ]);
    rrow "9112 §4"
      "the space after the code may be missing: the reason is nothing"
      "HTTP/1.1 204\r\n\r\n"
      (response ~reason:"" 204 []);
    rrow "9112 §4" "a reason may hold spaces"
      (status_line ~reason:"Not Found At All" 404 [ "Content-Length: 0" ] "")
      (response ~reason:"Not Found At All" 404 [ ("Content-Length", "0") ]);
    rrow "9112 §4" "a code of two digits is malformed" "HTTP/1.1 20 OK\r\n\r\n"
      Malformed;
    rrow "9112 §4" "a code of four digits is malformed"
      "HTTP/1.1 2000 OK\r\n\r\n" Malformed;
    rrow "9112 §4" "two spaces before the code is malformed"
      "HTTP/1.1  200 OK\r\n\r\n" Malformed;
    rrow "9110 §15" "a code below 100 is malformed" "HTTP/1.1 099 Early\r\n\r\n"
      Malformed;
    rrow "9110 §15" "a code above 599 is malformed" "HTTP/1.1 600 Late\r\n\r\n"
      Malformed;
    rrow "9112 §4" "a control character in the reason is malformed"
      "HTTP/1.1 200 O\001K\r\n\r\n" Malformed;
    rrow "9112 §2.3" "a version that is not HTTP/1.x is malformed"
      "HTTP/2.0 200 OK\r\n\r\n" Malformed;
    rrow "9112 §2.3" "a version spelled some other way is malformed"
      "http/1.1 200 OK\r\n\r\n" Malformed;
    rrow "9110 §6.2" "a later HTTP/1 minor version is read as HTTP/1.1"
      (status_line ~version:"HTTP/1.2" 200 ok_fields "hello")
      (response ~body:"hello" 200 ok_headers);
    rrow "9112 §2.2" "a line may end in a bare LF"
      "HTTP/1.1 200 OK\nContent-Length: 5\n\nhello"
      (response ~body:"hello" 200 ok_headers);
    rrow "9112 §2.2" "a bare CR is malformed"
      (status_line 200 [ "X-A: a\rb" ] "")
      Malformed;
    rrow "9112 §2.2" "an empty line before the status line is not skipped"
      ("\r\n" ^ status_line 200 ok_fields "hello")
      Malformed;
    rrow "9112 §5.2" "an obsolete fold is joined onto its field with SP"
      (status_line 200 [ "X-A: 1 "; "  2"; "\t3"; "Content-Length: 5" ] "hello")
      (response ~body:"hello" 200 [ ("X-A", "1 2 3"); ("Content-Length", "5") ]);
    rrow "9112 §2.2" "whitespace before the first field is malformed"
      (status_line 200 [ " X-A: 1" ] "")
      Malformed;
    rrow "9112 §5.1" "whitespace before a field's colon is malformed"
      (status_line 200 [ "X-A : 1" ] "")
      Malformed;
    rrow "9110 §5.1" "a field name that is not a token is malformed"
      (status_line 200 [ "X(A): 1" ] "")
      Malformed;
    rrow "9110 §5.5" "a control character in a field value is malformed"
      (status_line 200 [ "X-A: a\001b" ] "")
      Malformed;
    rrow "9110 §5.5" "a control character in a folded line is malformed"
      (status_line 200 [ "X-A: 1"; " a\001b" ] "")
      Malformed;
    rrow "9110 §5.4" "a head past the limit is malformed"
      (status_line 200 [ "X-Big: " ^ String.make 2000 'x' ] "")
      Malformed;
    rrow "9112 §8" "a head cut short is malformed"
      "HTTP/1.1 200 OK\r\nX-A: 1\r\n" Malformed;
    rrow "9112 §9.5"
      "the connection ending before a head is not a malformed one" ""
      Closed_first;
    rrow ~meth:`HEAD "9112 §6.3"
      "a response to HEAD has no body, whatever its length says"
      (status_line 200 ok_fields "hello")
      (response 200 ok_headers);
    rrow "9112 §6.3" "a 1xx has no body, and is a head of its own"
      (status_line ~reason:"Continue" 100 [] ""
      ^ status_line 200 ok_fields "hello")
      (response ~reason:"Continue" 100 []);
    rrow "9112 §6.3" "a 204 has no body, whatever its length says"
      (status_line ~reason:"No Content" 204 ok_fields "hello")
      (response ~reason:"No Content" 204 ok_headers);
    rrow "9112 §6.3" "a 304 has no body, whatever its length says"
      (status_line ~reason:"Not Modified" 304 ok_fields "hello")
      (response ~reason:"Not Modified" 304 ok_headers);
    rrow ~meth:(`Other "CONNECT") "9112 §6.3"
      "a 2xx to CONNECT has no body: the connection is a tunnel"
      (status_line 200 [] "tunnelled")
      (response 200 []);
    rrow "9112 §6.3" "a length is read to its end"
      (status_line 200 ok_fields "hello, and after")
      (response ~body:"hello" 200 ok_headers);
    rrow "9112 §6.3" "a list of identical lengths is one length"
      (status_line 200 [ "Content-Length: 5, 5" ] "hello")
      (response ~body:"hello" 200 [ ("Content-Length", "5, 5") ]);
    rrow "9112 §6.3" "a length that is not a number is refused"
      (status_line 200 [ "Content-Length: 5x" ] "hello")
      Unframed;
    rrow "9112 §6.3" "two different lengths are refused"
      (status_line 200 [ "Content-Length: 5"; "Content-Length: 6" ] "hello")
      Unframed;
    rrow "9112 §6.3" "a length past any int is refused"
      (status_line 200 [ "Content-Length: 99999999999999999999" ] "hello")
      Unframed;
    rrow "9112 §7.1"
      "a chunked body is read to its last chunk, the trailer apart"
      (status_line 200
         [ "Transfer-Encoding: chunked" ]
         "5\r\nhello\r\n1\r\n!\r\n0\r\nX-T: 1\r\n\r\n")
      (response ~body:"hello!" 200 te);
    rrow "9110 §5.6.1.2" "an empty list element is nothing: chunked, is chunked"
      (status_line 200 [ "Transfer-Encoding: , chunked," ] chunked_hello)
      (response ~body:"hello" 200 [ ("Transfer-Encoding", ", chunked,") ]);
    rrow "9112 §6.1" "chunked applied twice is refused"
      (status_line 200 [ "Transfer-Encoding: chunked, chunked" ] chunked_hello)
      Unframed;
    rrow "9112 §6.3"
      "a coding under chunked this reader does not decode is refused"
      (status_line 200 [ "Transfer-Encoding: gzip, chunked" ] chunked_hello)
      Unframed;
    rrow "9112 §6.3" "a coding that does not end in chunked is refused"
      (status_line 200 [ "Transfer-Encoding: gzip" ] "hello")
      Unframed;
    rrow "9112 §6.3" "both framings are refused"
      (status_line 200
         [ "Transfer-Encoding: chunked"; "Content-Length: 5" ]
         chunked_hello)
      Unframed;
    rrow "9112 §6.3"
      "neither length nor coding is a body to the connection's end"
      (status_line 200 [] "hello, and after")
      (response ~body:"hello, and after" 200 []);
    rrow "9112 §6.3" "a body to the connection's end may be empty"
      (status_line 200 [] "") (response 200 []);
    rrow "9112 §8" "a body cut short is broken"
      (status_line 200 [ "Content-Length: 10" ] "hel")
      Cut_short;
    rrow "9112 §8" "a chunked body cut short is broken"
      (status_line 200 [ "Transfer-Encoding: chunked" ] "5\r\nhel")
      Cut_short;
    rrow "9112 §7.1" "a chunk size past what an int holds is broken"
      (status_line 200
         [ "Transfer-Encoding: chunked" ]
         "ffffffffffffffffff\r\nx\r\n0\r\n\r\n")
      Cut_short;
    rrow "9112 §7.1" "a chunk-size line ending in a bare LF is broken"
      (status_line 200 [ "Transfer-Encoding: chunked" ] "5\nhello\r\n0\r\n\r\n")
      Cut_short;
    rrow "9112 §7.1.2" "a trailer line ending in a bare LF is broken"
      (status_line 200
         [ "Transfer-Encoding: chunked" ]
         "5\r\nhello\r\n0\r\nX-T: 1\n\r\n")
      Cut_short;
    rrow "9112 §6.1"
      "Transfer-Encoding in an HTTP/1.0 response is read, and the connection \
       not kept"
      (status_line ~version:"HTTP/1.0" 200
         [ "Connection: keep-alive"; "Transfer-Encoding: chunked" ]
         chunked_hello)
      (response ~version:Head.Http_1_0 ~kept:false ~body:"hello" 200
         (("Connection", "keep-alive") :: te));
    rrow "9112 §9.3" "HTTP/1.1 keeps its connection"
      (status_line 200 ok_fields "hello")
      (response ~body:"hello" 200 ok_headers);
    rrow "9112 §9.6" "HTTP/1.1 that says close does not"
      (status_line 200 ("Connection: keep-alive, close" :: ok_fields) "hello")
      (response ~kept:false ~body:"hello" 200
         (("Connection", "keep-alive, close") :: ok_headers));
    rrow "9112 §9.3" "HTTP/1.0 does not keep its connection"
      (status_line ~version:"HTTP/1.0" 200 ok_fields "hello")
      (response ~version:Head.Http_1_0 ~kept:false ~body:"hello" 200 ok_headers);
    rrow "9112 §9.3" "HTTP/1.0 that says keep-alive does"
      (status_line ~version:"HTTP/1.0" 200
         ("Connection: keep-alive" :: ok_fields)
         "hello")
      (response ~version:Head.Http_1_0 ~body:"hello" 200
         (("Connection", "keep-alive") :: ok_headers));
    rrow "9112 §9.3" "HTTP/1.0 that says close beside keep-alive does not"
      (status_line ~version:"HTTP/1.0" 200
         ("Connection: keep-alive, close" :: ok_fields)
         "hello")
      (response ~version:Head.Http_1_0 ~kept:false ~body:"hello" 200
         (("Connection", "keep-alive, close") :: ok_headers));
  ]

(* ------------------------------------------------------------------ *)
(* Running a row *)

let check_reading (row : row) delivery =
  let got = read delivery row.bytes in
  let fail () =
    Alcotest.failf "%s: %s, read %s: %s" row.rfc row.says
      (delivery_name delivery) (show got)
  in
  match (row.owes, got) with
  | Parsed p, Read (h, body) ->
      if
        not
          (String.equal p.meth (Meth.to_string h.meth)
          && String.equal p.target h.target
          && String.equal (version_name p.version) (version_name h.version)
          && List.equal
               (fun (a, b) (c, d) -> String.equal a c && String.equal b d)
               p.headers h.headers
          && Option.equal String.equal p.host h.host
          && String.equal p.body body)
      then fail ()
  | Refused s, Head_refused (Head.Refused (s', _)) ->
      if s <> Status.to_int s' then fail ()
  | Unframed_as s, Unframed (_, s') -> if s <> s' then fail ()
  | Body_broken, Broken _ | Body_too_large, Too_large _ -> ()
  | (Parsed _ | Refused _ | Unframed_as _ | Body_broken | Body_too_large), _ ->
      fail ()
  | Answers _, _ -> Alcotest.fail "a server row read as a head"

let check_response (row : response_row) delivery =
  let got = read_response ~meth:row.meth delivery row.bytes in
  let fail () =
    Alcotest.failf "%s: %s, read %s: %s" row.rfc row.says
      (delivery_name delivery) (show_response got)
  in
  match (row.owes, got) with
  | Response_is p, Response_read (h, body) ->
      if
        not
          (String.equal (version_name p.version) (version_name h.version)
          && p.status = Status.to_int h.status
          && String.equal p.reason h.reason
          && List.equal
               (fun (a, b) (c, d) -> String.equal a c && String.equal b d)
               p.headers h.headers
          && String.equal p.body body
          && Bool.equal p.kept (Head.Response.keep_alive h))
      then fail ()
  | Malformed, Response_malformed
  | Closed_first, Response_closed
  | Unframed, Response_unframed _
  | Cut_short, Response_broken _ ->
      ()
  | (Response_is _ | Malformed | Closed_first | Unframed | Cut_short), _ ->
      fail ()

let response_case (row : response_row) =
  Alcotest.test_case (Printf.sprintf "%s: %s" row.rfc row.says) `Quick
    (fun () ->
      Eio_mock.Backend.run @@ fun () ->
      check_response row Whole;
      check_response row Bytewise)

let probe = get "/id/probe"

let check_answers env connect (row : row) delivery =
  match row.owes with
  | Parsed _ | Refused _ | Unframed_as _ | Body_broken | Body_too_large ->
      Alcotest.fail "a head row sent to the server"
  | Answers (answers, ending) -> (
      let where =
        Printf.sprintf "%s: %s, sent %s" row.rfc row.says
          (delivery_name delivery)
      in
      let bytes =
        match ending with Open -> row.bytes ^ probe | Closed -> row.bytes
      in
      converse env connect delivery bytes @@ fun r ->
      List.iteri
        (fun i (a : answer) ->
          let got : answered = read_answer ~head:a.to_head r in
          let at = Printf.sprintf "%s, answer %d" where (i + 1) in
          Alcotest.(check int) (at ^ ": status") a.status got.status;
          Option.iter
            (fun b -> Alcotest.(check string) (at ^ ": body") b got.body)
            a.body;
          List.iter
            (fun (name, owed) ->
              let values = Field.all got.headers name in
              if not (holds owed values) then
                Alcotest.failf "%s: %s is %s" at name (shown values))
            a.headers)
        answers;
      match ending with
      | Closed -> Alcotest.(check bool) (where ^ ": closed") true (at_end r)
      | Open ->
          Alcotest.(check string)
            (where ^ ": still open, and nothing else answered")
            "probe" (read_answer ~head:false r).body)

let reading_case (row : row) =
  Alcotest.test_case (Printf.sprintf "%s: %s" row.rfc row.says) `Quick
    (fun () ->
      Eio_mock.Backend.run @@ fun () ->
      check_reading row Whole;
      check_reading row Bytewise)

let server_case (row : row) =
  Alcotest.test_case (Printf.sprintf "%s: %s" row.rfc row.says) `Quick
    (fun () ->
      In_memory.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let connect = serve ~sw env in
      check_answers env connect row Whole;
      check_answers env connect row Bytewise)

(* ------------------------------------------------------------------ *)
(* The client, against a scripted server *)

(* What the scripted server does on one connection, in order. It reads
   requests with Spindle's own reader, which is the strict one; a request
   it cannot read fails the row. *)
type act =
  | Answer of string  (** reads a request, then writes these bytes *)
  | Every of string
      (** answers every request with these bytes, while the connection lasts *)
  | Hang_up  (** closes the connection *)
  | Shut_down  (** ends what it writes, as a close does, and reads on *)
  | Await_close
      (** reads the connection beneath any TLS to its end: whatever a client
          sends once it is done, a closure alert included *)

(* What a row's server saw: every connection the client opened, every
   request it sent, and how it left each connection. *)
type seen = {
  mutable opened : int;
  mutable requests : (Head.Request.t * string) list;  (** newest first *)
  mutable unscripted : int;
      (** requests on a connection whose script had ended: one the client should
          not have used again *)
  mutable unreadable : string list;
  mutable hung_up : int list;  (** the connections the client closed *)
  mutable alerted : (int * bool) list;
      (** after [Await_close]: whether anything came before the end *)
  changed : Eio.Condition.t;
}

type returns = Gives of answer | Fails

type call = {
  meth : Meth.t;
  path : string;
  userinfo : string option;
  headers : (string * string) list;
  body : string option;
  after : float;
      (** the seconds that pass before it, for an idle limit to run out *)
  once_closed : int option;
      (** made once the client has closed this connection, counted from 0, for
          what it noticed to have been acted on *)
}

(* What the server must have seen by the row's end. *)
type saw =
  | Connections of int
  | Requests of int
  | Host_first
      (** every request's first field is [Host], the URI's authority less its
          userinfo *)
  | Targets of string list  (** the requests' targets, in order *)
  | Sent of string * header  (** a field of every request *)
  | Bodies of string list
  | Hung_up of int  (** the client closed this connection, counted from 0 *)
  | Alerted of int  (** and closed it with a TLS closure alert *)

(* What the suite's certificate names, for a TLS row: the loopback address
   the rows call, or a name alone -- which a call to the address must then
   refuse. *)
type certified = Name_and_address | Name_only

type client_row = {
  rfc : string;
  says : string;
  tls : certified option;
  foreign : bool;
      (** the calls are made from a domain the client is not on: nothing is kept
          there, so each opens a connection and closes it after *)
  by_name : bool;
      (** the calls name [localhost], and the server listens only on the last
          address it resolves to, so a client that tries the first alone never
          connects *)
  max_body : int option;
  first : act list list;  (** the scripts of the first connections, in order *)
  later : act list;  (** the script of every connection after them *)
  calls : (call * returns) list;  (** made one after another *)
  saw : saw list;
}

let call ?(meth = `GET) ?(path = "/") ?userinfo ?(headers = []) ?body
    ?(after = 0.) ?once_closed returns =
  ({ meth; path; userinfo; headers; body; after; once_closed }, returns)

let gives ?body ?headers status = Gives (answer ?body ?headers status)

let ok_with body =
  status_line 200
    [ Printf.sprintf "Content-Length: %d" (String.length body) ]
    body

let ok = ok_with "ok"

let ok_then_close =
  status_line 200 [ "Connection: close"; "Content-Length: 2" ] "ok"

let crow ?tls ?(foreign = false) ?(by_name = false) ?max_body ?(first = [])
    ?(later = [ Every ok ]) ?(saw = []) rfc says calls =
  { rfc; says; tls; foreign; by_name; max_body; first; later; calls; saw }

let ok_call = call (gives ~body:"ok" 200)

let client_rows =
  [
    crow "9112 §3.2, 9110 §7.2"
      "Host is sent first, the URI's authority less its userinfo"
      ~saw:[ Host_first ]
      [ call ~userinfo:"kim:secret" (gives ~body:"ok" 200) ];
    crow "9112 §3.2.1" "the target is origin-form, and / for an empty path"
      ~saw:[ Targets [ "/"; "/a/b?c=d" ] ]
      [ call ~path:"" (gives 200); call ~path:"/a/b?c=d" (gives 200) ];
    crow "9112 §6.3" "a body is sent with its length, never chunked"
      ~saw:
        [
          Sent ("content-length", Is "5");
          Sent ("transfer-encoding", Absent);
          Bodies [ "hello" ];
        ]
      [ call ~meth:`POST ~body:"hello" (gives 200) ];
    crow "9110 §8.6" "a POST with no body says its length is 0"
      ~saw:[ Sent ("content-length", Is "0") ]
      [ call ~meth:`POST (gives 200) ];
    crow "9110 §8.6" "a GET with no body sends no length"
      ~saw:
        [ Sent ("content-length", Absent); Sent ("transfer-encoding", Absent) ]
      [ ok_call ];
    crow "9112 §6.3" "a response to HEAD has no body, whatever its length says"
      ~first:[ [ Answer (status_line 200 ok_fields ""); Every ok ] ]
      [
        call ~meth:`HEAD
          (gives ~body:"" ~headers:[ ("content-length", Is "5") ] 200);
        ok_call;
      ];
    crow "9112 §6.3" "a 204 has no body, whatever its length says"
      ~first:
        [
          [
            Answer (status_line ~reason:"No Content" 204 ok_fields ""); Every ok;
          ];
        ]
      [ call (gives ~body:"" 204); ok_call ];
    crow "9112 §6.3" "a 304 has no body, whatever its length says"
      ~first:
        [
          [
            Answer (status_line ~reason:"Not Modified" 304 ok_fields "");
            Every ok;
          ];
        ]
      [ call (gives ~body:"" 304); ok_call ];
    crow "9110 §15.2" "a 1xx before the final response is skipped"
      ~later:[ Every (status_line ~reason:"Continue" 100 [] "" ^ ok) ]
      [ ok_call; ok_call ];
    crow "9110 §15.2" "several 1xx, with fields of their own, are skipped"
      ~later:
        [
          Every
            (status_line ~reason:"Early Hints" 103 [ "Link: </a>" ] ""
            ^ status_line ~reason:"Continue" 100 [] ""
            ^ ok);
        ]
      [ call (gives ~body:"ok" ~headers:[ ("link", Absent) ] 200) ];
    crow "9112 §7.1"
      "a chunked response is read to its last chunk, the trailer apart"
      ~later:
        [
          Every
            (status_line 200
               [ "Transfer-Encoding: chunked" ]
               "5\r\nhello\r\n1\r\n!\r\n0\r\nX-T: 1\r\n\r\n");
        ]
      [
        call (gives ~body:"hello!" ~headers:[ ("x-t", Absent) ] 200);
        call (gives ~body:"hello!" 200);
      ];
    crow "9112 §6.3" "a length is read to its end" [ ok_call; ok_call ];
    crow "9112 §6.3"
      "neither length nor coding is a body to the connection's end"
      ~later:[ Answer (status_line 200 [] "hello"); Hang_up ]
      [ call (gives ~body:"hello" 200) ];
    crow "9112 §6.3" "both framings are an error, and the connection closed"
      ~later:
        [
          Answer
            (status_line 200
               [ "Transfer-Encoding: chunked"; "Content-Length: 5" ]
               chunked_hello);
        ]
      ~saw:[ Hung_up 0 ]
      [ call Fails ];
    crow "9112 §5.2" "an obsolete fold in a response is replaced with SP"
      ~later:
        [
          Every (status_line 200 [ "X-A: 1"; "  2"; "Content-Length: 2" ] "ok");
        ]
      [ call (gives ~headers:[ ("x-a", Is "1 2") ] 200) ];
    crow "9112 §6.1"
      "Transfer-Encoding in an HTTP/1.0 response is read, and the connection \
       not reused"
      ~first:
        [
          [
            Answer
              (status_line ~version:"HTTP/1.0" 200
                 [ "Connection: keep-alive"; "Transfer-Encoding: chunked" ]
                 chunked_hello);
          ];
        ]
      ~saw:[ Connections 2; Hung_up 0 ]
      [ call (gives ~body:"hello" 200); ok_call ];
    crow "9112 §6.3" "an invalid length is an error, and the connection closed"
      ~later:[ Answer (status_line 200 [ "Content-Length: 5x" ] "hello") ]
      ~saw:[ Hung_up 0 ]
      [ call Fails ];
    crow "9112 §8" "a head cut short is an error"
      ~later:[ Answer "HTTP/1.1 200 OK\r\nContent-Le"; Hang_up ]
      [ call Fails ];
    crow "9112 §8" "a body cut short is an error"
      ~later:
        [ Answer (status_line 200 [ "Content-Length: 10" ] "hel"); Hang_up ]
      [ call Fails ];
    crow "9112 §8" "a chunked body cut short is an error"
      ~later:
        [
          Answer (status_line 200 [ "Transfer-Encoding: chunked" ] "5\r\nhel");
          Hang_up;
        ]
      [ call Fails ];
    crow "9112 §9.3" "ten calls to one host open one connection"
      ~saw:[ Connections 1 ]
      (List.init 10 (fun _ -> ok_call));
    crow ~foreign:true "Spindle, per domain"
      "a call from a domain the client is not on keeps no connection"
      ~saw:[ Connections 2 ] [ ok_call; ok_call ];
    crow "9112 §9.3"
      "a connection past the server's Keep-Alive timeout is not used again"
      ~first:
        [
          [
            Answer
              (status_line 200
                 [ "Content-Length: 2"; "Keep-Alive: timeout=1" ]
                 "ok");
          ];
        ]
      ~saw:[ Connections 2 ]
      [ ok_call; call ~after:1.2 (gives 200) ];
    crow "9112 §9.5"
      "a connection is not lent in the server's last second of Keep-Alive"
      ~first:
        [
          [
            Answer
              (status_line 200
                 [ "Content-Length: 2"; "Keep-Alive: timeout=2" ]
                 "ok");
          ];
        ]
      ~saw:[ Connections 2 ]
      [ ok_call; call ~after:1.2 (gives 200) ];
    crow "9112 §9.5" "a server's Keep-Alive of a second keeps no connection"
      ~first:
        [
          [
            Answer
              (status_line 200
                 [ "Content-Length: 2"; "Keep-Alive: timeout=1" ]
                 "ok");
          ];
        ]
      ~saw:[ Connections 2 ] [ ok_call; ok_call ];
    crow ~by_name:true "RFC 1123 §2.3"
      "every address a name has is tried until one connects"
      [ ok_call; ok_call ];
    crow "9112 §9.3" "a connection the server said close on is not used again"
      ~first:[ [ Answer ok_then_close ] ]
      ~saw:[ Connections 2; Hung_up 0 ]
      [ ok_call; ok_call ];
    crow "9112 §9.3" "a connection the caller said close on is not used again"
      ~first:[ [ Answer ok ] ]
      ~saw:[ Connections 2; Hung_up 0 ]
      [ call ~headers:[ ("connection", "close") ] (gives 200); ok_call ];
    crow "9112 §9.3"
      "a connection whose response was not read to its end is not used again"
      ~max_body:50
      ~first:[ [ Answer (ok_with (String.make 100 'x')) ] ]
      ~saw:[ Connections 2; Hung_up 0 ]
      [ call Fails; ok_call ];
    crow "9112 §9.5"
      "an idle connection's close is noticed, so a POST after it goes to a new \
       one"
      ~first:[ [ Answer ok; Shut_down; Await_close ] ]
      ~saw:[ Connections 2 ]
      [ ok_call; call ~meth:`POST ~body:"x" ~once_closed:0 (gives 200) ];
    crow "9112 §9.3.2"
      "a GET that met the connection's end before a byte of its answer is sent \
       again"
      ~first:[ [ Answer ok; Answer ""; Hang_up ] ]
      [ ok_call; ok_call ];
    crow "9112 §9.3.2" "a POST that was sent is never sent twice"
      ~first:[ [ Answer ok; Answer ""; Hang_up ] ]
      ~later:[ Answer ""; Hang_up ] ~saw:[ Requests 2 ]
      [ ok_call; call ~meth:`POST ~body:"x" Fails ];
    crow ~tls:Name_and_address "9112 §9.3"
      "a kept TLS connection carries the next call" ~saw:[ Connections 1 ]
      [ ok_call; call ~meth:`POST ~body:"x" (gives 200) ];
    crow ~tls:Name_and_address "9112 §9.8"
      "a TLS connection is closed with a closure alert"
      ~later:[ Answer ok_then_close; Await_close ]
      ~saw:[ Alerted 0 ] [ ok_call ];
    crow ~tls:Name_only "9110 §4.3.4, RFC 6125 §6.4"
      "a host that is an address is checked against the certificate, as a name \
       is"
      [ call Fails ];
  ]

(* A certificate of the suite's own, naming what [certified] says, and an
   authenticator that trusts its key and nothing else -- and checks the
   name or address the client says it is calling, as a real one does: what
   a TLS row's server and client are given. *)
let tls_pair =
  let make certified =
    Mirage_crypto_rng_unix.use_default ();
    let key = X509.Private_key.generate `P256 in
    let name =
      X509.Distinguished_name.
        [
          Relative_distinguished_name.singleton (CN (Common_name.v "localhost"));
        ]
    in
    let names = X509.General_name.singleton DNS [ "localhost" ] in
    let names =
      match certified with
      | Name_and_address ->
          X509.General_name.add IP
            [ Ipaddr.V4.to_octets Ipaddr.V4.localhost ]
            names
      | Name_only -> names
    in
    let extensions = X509.Extension.singleton Subject_alt_name (false, names) in
    let certificate =
      match X509.Signing_request.create name key with
      | Error (`Msg m) -> Alcotest.fail m
      | Ok csr -> (
          match
            X509.Signing_request.sign csr ~valid_from:Ptime.epoch
              ~valid_until:
                (Option.value (Ptime.of_float_s 4e9) ~default:Ptime.max)
              ~extensions key name
          with
          | Ok c -> c
          | Error e -> Alcotest.failf "%a" X509.Validation.pp_signature_error e)
    in
    let config =
      match
        Tls.Config.server ~certificates:(`Single ([ certificate ], key)) ()
      with
      | Ok c -> c
      | Error (`Msg m) -> Alcotest.fail m
    in
    let fingerprint =
      X509.Public_key.fingerprint ~hash:`SHA256 (X509.Private_key.public key)
    in
    let authenticator : X509.Authenticator.t =
     fun ?ip ~host chain ->
      X509.Validation.trust_key_fingerprint ?ip ~host
        ~time:(fun () -> Ptime.of_float_s (Unix.gettimeofday ()))
        ~hash:`SHA256 ~fingerprint chain
    in
    (config, authenticator)
  in
  let both = lazy (make Name_and_address) and name = lazy (make Name_only) in
  function Name_and_address -> Lazy.force both | Name_only -> Lazy.force name

(* One connection, as its script says. *)
let script ~tls ~delivery seen i socket acts =
  let note f =
    f ();
    Eio.Condition.broadcast seen.changed
  in
  let gone () = note (fun () -> seen.hung_up <- i :: seen.hung_up) in
  let unreadable d = note (fun () -> seen.unreadable <- d :: seen.unreadable) in
  let flow =
    match tls with
    | None -> Ok (socket :> Eio.Flow.two_way_ty Eio.Resource.t)
    | Some config -> (
        match Tls_eio.server_of_flow config socket with
        | t -> Ok (t :> Eio.Flow.two_way_ty Eio.Resource.t)
        | exception ex -> Error (Printexc.to_string ex))
  in
  match flow with
  | Error m -> unreadable ("a TLS handshake: " ^ m)
  | Ok flow ->
      let r = Eio.Buf_read.of_flow flow ~max_size:65536 in
      let next () =
        match Head.Request.read ~max:65536 r with
        | Error Head.Closed -> `Gone
        | Error (Head.Refused (_, detail)) -> `Unreadable detail
        | Ok head -> (
            match Framing.of_request head with
            | Error (_, detail) -> `Unreadable detail
            | Ok framing -> (
                let body = Framing.reader framing r ~max_trailer:65536 in
                match Framing.read body ~max:65536 ~reserve:(fun _ -> true) with
                | Ok body -> `Request (head, body)
                | Error _ -> `Unreadable "a request's body"))
        | exception (End_of_file | Eio.Io _) -> `Gone
      in
      (* Each piece its own segment; where the client's reads fall is the
         kernel's to say, and the reading rows are where a cut is chosen. *)
      let send s =
        try List.iter (fun p -> Eio.Flow.copy_string p flow) (split delivery s)
        with Eio.Io _ -> ()
      in
      let answer s ~then_ =
        match next () with
        | `Request rq ->
            note (fun () -> seen.requests <- rq :: seen.requests);
            send s;
            then_ ()
        | `Gone -> gone ()
        | `Unreadable d -> unreadable d
      in
      let rec go = function
        | [] -> (
            match next () with
            | `Request _ ->
                note (fun () -> seen.unscripted <- seen.unscripted + 1)
            | `Gone -> gone ()
            | `Unreadable d -> unreadable d)
        | Answer s :: rest -> answer s ~then_:(fun () -> go rest)
        | Every s :: rest -> answer s ~then_:(fun () -> go (Every s :: rest))
        | Hang_up :: _ -> ()
        | Shut_down :: rest ->
            (try Eio.Flow.shutdown flow `Send with Eio.Io _ -> ());
            go rest
        | Await_close :: _ ->
            let buf = Cstruct.create 4096 in
            let rec drain n =
              match Eio.Flow.single_read socket buf with
              | k -> drain (n + k)
              | exception (End_of_file | Eio.Io _) -> n
            in
            let n = drain 0 in
            note (fun () ->
                seen.alerted <- (i, n > 0) :: seen.alerted;
                seen.hung_up <- i :: seen.hung_up)
      in
      go acts

(* A row, the server's answers delivered as [delivery] says: [Ok ()], or
   every way it went wrong. *)
let run_client_row env (row : client_row) delivery =
  let clock = Eio.Stdenv.clock env in
  let seen =
    {
      opened = 0;
      requests = [];
      unscripted = 0;
      unreadable = [];
      hung_up = [];
      alerted = [];
      changed = Eio.Condition.create ();
    }
  in
  let tls = Option.map tls_pair row.tls in
  let host, listening =
    if row.by_name then
      match
        List.rev (Eio.Net.getaddrinfo_stream (Eio.Stdenv.net env) "localhost")
      with
      | `Tcp (ip, _) :: _ -> ("localhost", ip)
      | `Unix _ :: _ | [] -> Alcotest.fail "localhost has no address"
    else ("127.0.0.1", Eio.Net.Ipaddr.V4.loopback)
  in
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:16 ~reuse_addr:true
      (`Tcp (listening, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let rec accept () =
        Eio.Net.accept_fork socket ~sw
          ~on_error:(fun ex ->
            seen.unreadable <- Printexc.to_string ex :: seen.unreadable)
          (fun flow _ ->
            let i = seen.opened in
            seen.opened <- i + 1;
            Eio_unix.Fd.use_exn "nodelay" (Eio_unix.Net.fd flow) (fun fd ->
                Unix.setsockopt fd Unix.TCP_NODELAY true);
            let acts =
              match List.nth_opt row.first i with
              | Some acts -> acts
              | None -> row.later
            in
            script ~tls:(Option.map fst tls) ~delivery seen i flow acts);
        accept ()
      in
      accept ())
    (fun () ->
      let client =
        Spindle_client.create ~sw ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ?max_body:row.max_body ?authenticator:(Option.map snd tls) ()
      in
      let failures = ref [] in
      let fail fmt =
        Printf.ksprintf (fun m -> failures := m :: !failures) fmt
      in
      (* What a client does to a connection -- a close, an alert -- is
         waited for. *)
      let await pred =
        Eio.Condition.loop_no_mutex seen.changed (fun () ->
            if pred () then Some () else None)
      in
      let calls () =
        List.iteri
          (fun n ((c : call), returns) ->
            if c.after > 0. then Eio.Time.sleep clock c.after;
            Option.iter
              (fun i -> await (fun () -> List.mem i seen.hung_up))
              c.once_closed;
            let url =
              Printf.sprintf "%s://%s%s:%d%s"
                (if Option.is_some row.tls then "https" else "http")
                (match c.userinfo with Some u -> u ^ "@" | None -> "")
                host port c.path
            in
            match
              ( returns,
                Spindle_client.call client ~headers:c.headers ?body:c.body
                  c.meth url )
            with
            | Fails, Error _ -> ()
            | Fails, Ok r ->
                fail "call %d was answered %d where it owed an error" (n + 1)
                  r.status
            | Gives _, Error e ->
                fail "call %d: %s" (n + 1) (Spindle_client.error_to_string e)
            | Gives a, Ok r ->
                if a.status <> r.status then
                  fail "call %d: status %d, owed %d" (n + 1) r.status a.status;
                Option.iter
                  (fun b ->
                    if not (String.equal b r.body) then
                      fail "call %d: body %S, owed %S" (n + 1) r.body b)
                  a.body;
                List.iter
                  (fun (name, owed) ->
                    let values = Field.all r.headers name in
                    if not (holds owed values) then
                      fail "call %d: %s is %s" (n + 1) name (shown values))
                  a.headers)
          row.calls
      in
      if row.foreign then
        Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) calls
      else calls ();
      List.iter
        (function
          | Hung_up i -> await (fun () -> List.mem i seen.hung_up)
          | Alerted i -> await (fun () -> List.mem_assoc i seen.alerted)
          | Connections _ | Requests _ | Host_first | Targets _ | Sent _
          | Bodies _ ->
              ())
        row.saw;
      let requests = List.rev seen.requests in
      let heads = List.map fst requests in
      List.iter
        (function
          | Connections n ->
              if seen.opened <> n then
                fail "%d connections opened, where %d were owed" seen.opened n
          | Requests n ->
              if List.length requests <> n then
                fail "%d requests arrived, where %d were owed"
                  (List.length requests) n
          | Host_first ->
              let host = Printf.sprintf "127.0.0.1:%d" port in
              List.iter
                (fun (h : Head.Request.t) ->
                  match h.headers with
                  | (k, v) :: _
                    when String.equal (String.lowercase_ascii k) "host"
                         && String.equal v host ->
                      ()
                  | _ ->
                      fail "a request not led by Host: %s: %s" host
                        (show_head h))
                heads
          | Targets ts ->
              let got = List.map (fun (h : Head.Request.t) -> h.target) heads in
              if not (List.equal String.equal ts got) then
                fail "targets %s, owed %s" (String.concat " " got)
                  (String.concat " " ts)
          | Sent (name, owed) ->
              List.iter
                (fun (h : Head.Request.t) ->
                  let values = Field.all h.headers name in
                  if not (holds owed values) then
                    fail "a request whose %s is %s" name (shown values))
                heads
          | Bodies bs ->
              let got = List.map snd requests in
              if not (List.equal String.equal bs got) then
                fail "bodies %s, owed %s"
                  (String.concat " " (List.map (Printf.sprintf "%S") got))
                  (String.concat " " (List.map (Printf.sprintf "%S") bs))
          | Hung_up i ->
              if not (List.mem i seen.hung_up) then
                fail "connection %d was never closed" (i + 1)
          | Alerted i -> (
              match List.assoc_opt i seen.alerted with
              | Some true -> ()
              | Some false ->
                  fail "connection %d was closed with no closure alert" (i + 1)
              | None -> fail "connection %d was never closed" (i + 1)))
        row.saw;
      if seen.unscripted > 0 then
        fail "%d requests on a connection that should not have carried one"
          seen.unscripted;
      List.iter (fail "a request the server could not read: %s") seen.unreadable;
      match List.rev !failures with
      | [] -> Ok ()
      | fs -> Error (String.concat "; " fs))

let client_row_name (row : client_row) =
  Printf.sprintf "%s: %s" row.rfc row.says

(* A server of plain sockets on threads of its own, listening on a
   Unix-domain socket: each connection's every request is answered with that
   connection's number, counted from 0, and [connection n] is the [n]th's own
   socket, for a test to write to or shut down itself. Acting on it is a
   system call the test's domain makes without running anything else, so
   the client's fibers -- the watch on a kept connection among them -- learn
   of it only once the test lets them; and a Unix-domain socket's write is in
   its reader's buffer as the call returns, where loopback TCP's may still be
   on its way through the kernel. *)
let plain_server () =
  let path = Filename.temp_file "spindle_plain" ".sock" in
  Sys.remove path;
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX path);
  Unix.listen listener 8;
  let accepted = ref [] and lock = Mutex.create () in
  let stopping = Atomic.make false in
  let answer fd n =
    let buf = Bytes.create 4096 and pending = Buffer.create 256 in
    let body = string_of_int n in
    let reply =
      Printf.sprintf "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s"
        (String.length body) body
    in
    let rec requests () =
      match Unix.read fd buf 0 (Bytes.length buf) with
      | 0 -> ()
      | k ->
          Buffer.add_subbytes pending buf 0 k;
          (* Each head ends in an empty line; the calls here carry no body
             the server need read. *)
          let rec each () =
            let text = Buffer.contents pending in
            let rec head_end i =
              if i + 4 > String.length text then None
              else if String.equal (String.sub text i 4) "\r\n\r\n" then
                Some (i + 4)
              else head_end (i + 1)
            in
            match head_end 0 with
            | Some i ->
                Buffer.clear pending;
                Buffer.add_string pending
                  (String.sub text i (String.length text - i));
                ignore (Unix.write_substring fd reply 0 (String.length reply));
                each ()
            | None -> ()
          in
          each ();
          requests ()
      | exception Unix.Unix_error _ -> ()
    in
    requests ()
  in
  let rec accept () =
    match Unix.accept listener with
    | fd, _ when Atomic.get stopping -> Unix.close fd
    | fd, _ ->
        let n =
          Mutex.protect lock (fun () ->
              accepted := !accepted @ [ fd ];
              List.length !accepted - 1)
        in
        ignore (Thread.create (fun () -> answer fd n) () : Thread.t);
        accept ()
    | exception Unix.Unix_error _ -> ()
  in
  let accepting = Thread.create accept () in
  let connection n =
    match Mutex.protect lock (fun () -> List.nth_opt !accepted n) with
    | Some fd -> fd
    | None -> Alcotest.failf "no connection %d" n
  in
  (* A connection of its own wakes the accept to see it is to stop: closing
     the socket under a thread blocked in it wakes nothing everywhere. *)
  let stop () =
    Atomic.set stopping true;
    let last = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Unix.connect last (Unix.ADDR_UNIX path);
    Unix.close last;
    Thread.join accepting;
    Unix.close listener;
    Sys.remove path
  in
  (path, connection, stop)

(* A network that resolves every name to one Unix-domain socket's path: all
   a client asks of a network is where a name is, and the rest of it is the
   client's own. *)
module Only_path = struct
  type t = string
  type tag = [ `Generic ]

  let listen _ ~reuse_addr:_ ~reuse_port:_ ~backlog:_ ~sw:_ _ =
    Alcotest.fail "a client listens on nothing"

  let connect _ ~bind_to:_ ~options:_ ~sw:_ _ =
    Alcotest.fail "the client connects its own sockets"

  let datagram_socket _ ~reuse_addr:_ ~reuse_port:_ ~sw:_ _ =
    Alcotest.fail "a client sends no datagrams"

  let getaddrinfo path ~service:_ _ = [ `Unix path ]
  let getnameinfo _ _ = Alcotest.fail "a client names no address"
end

(* A client of [plain_server] at [path]. *)
let plain_client ~sw env path =
  Spindle_client.create ~sw
    ~net:(Eio.Resource.T (path, Eio.Net.Pi.network (module Only_path)))
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ()

(* RFC 9112 §9.2: bytes a server wrote on a kept connection are no answer
   to the next call, which goes on a new connection -- however soon after
   they arrived it is made, before the connection's watch has run. *)
let test_bytes_on_a_kept_connection_are_not_the_next_answer () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let path, connection, stop = plain_server () in
  Fun.protect ~finally:stop @@ fun () ->
  let client = plain_client ~sw env path in
  let body () =
    match Spindle_client.call client `GET "http://plain/" with
    | Ok r -> r.body
    | Error e -> Alcotest.fail (Spindle_client.error_to_string e)
  in
  Alcotest.(check string) "the first call, on connection 0" "0" (body ());
  let stray = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nstale" in
  ignore (Unix.write_substring (connection 0) stray 0 (String.length stray));
  Alcotest.(check string) "the next, on a new one" "1" (body ())

(* RFC 9112 §9.5: a kept connection the server has closed is not lent, so
   a call that may not be sent twice -- a POST -- is not sent into it,
   however soon after the close it is made. *)
let test_a_kept_connection_the_server_closed_is_not_lent () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let path, connection, stop = plain_server () in
  Fun.protect ~finally:stop @@ fun () ->
  let client = plain_client ~sw env path in
  let body meth =
    match Spindle_client.call client meth ~body:"x" "http://plain/" with
    | Ok r -> r.body
    | Error e -> Alcotest.fail (Spindle_client.error_to_string e)
  in
  Alcotest.(check string) "the first call, on connection 0" "0" (body `GET);
  Unix.shutdown (connection 0) Unix.SHUTDOWN_ALL;
  Alcotest.(check string) "a POST after it, on a new one" "1" (body `POST)

(* RFC 9112 §9.2, under TLS: bytes that came in the same record as the end
   of an answer are no answer to the next call either. Decrypted with it,
   they wait in the TLS layer, where the socket shows nothing of them. The
   answer is exactly what a client's reader takes on its first read -- Eio's
   buffer starts at 4096 bytes -- so every one of them is left there. *)
let test_bytes_after_a_tls_answer_are_not_the_next_answer () =
  Eio_main.run @@ fun env ->
  let head = String.length (ok_with (String.make 1000 'x')) - 1000 in
  let answer = ok_with (String.make (4096 - head) 'x') in
  Alcotest.(check int) "an answer of one read" 4096 (String.length answer);
  let row =
    crow ~tls:Name_and_address "9112 §9.2"
      "bytes after a TLS answer are not the next answer"
      ~first:[ [ Answer (answer ^ ok_with "stale") ] ]
      ~later:[ Every (ok_with "fresh") ]
      ~saw:[ Connections 2 ]
      [ call (gives 200); call (gives ~body:"fresh" 200) ]
  in
  match run_client_row env row Whole with
  | Ok () -> ()
  | Error why -> Alcotest.fail why

let client_case (row : client_row) =
  let name = client_row_name row in
  Alcotest.test_case name `Quick (fun () ->
      Eio_main.run @@ fun env ->
      List.iter
        (fun delivery ->
          match run_client_row env row delivery with
          | Ok () -> ()
          | Error why ->
              Alcotest.failf "%s, answered %s: %s" name (delivery_name delivery)
                why)
        [ Whole; Bytewise ])

(* ------------------------------------------------------------------ *)
(* What the writer owes *)

let written f =
  Eio_mock.Backend.run @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let oc = Eio.Buf_write.create ~sw 256 in
  let result = f oc in
  (result, Eio.Buf_write.serialize_to_string oc)

let test_the_space_after_the_code_is_written_with_no_reason () =
  let result, bytes =
    written (fun oc -> Write.response_head oc (`Code 599) [])
  in
  Alcotest.(check bool) "written" true (Result.is_ok result);
  Alcotest.(check string) "the space stays" "HTTP/1.1 599 \r\n\r\n" bytes

let test_a_value_that_could_split_is_never_written () =
  List.iter
    (fun (name, value) ->
      let result, bytes =
        written (fun oc ->
            Write.response_head oc `OK [ ("x-a", "1"); (name, value) ])
      in
      Alcotest.(check bool)
        (Printf.sprintf "%S refused" value)
        true
        (match result with
        | Error (`Field n) -> String.equal n name
        | Ok () | Error `Status -> false);
      Alcotest.(check string) "and nothing of the head written" "" bytes)
    [
      ("x-b", "a\r\nx-evil: 1");
      ("x-b", "a\nb");
      ("x-b", "a\rb");
      ("x-b", "a\000b");
      ("x-b", "a\001b");
      ("x-b", "a\127b");
      ("x b", "a");
      ("", "a");
    ]

(* RFC 9110 §15: a status is from 100 to 599, which is what a reader takes. *)
let test_a_status_the_reader_refuses_is_never_written () =
  List.iter
    (fun (n, owed) ->
      let result, bytes =
        written (fun oc -> Write.response_head oc (Status.of_int n) [])
      in
      Alcotest.(check bool)
        (Printf.sprintf "%d %s" n (if owed then "written" else "refused"))
        owed (Result.is_ok result);
      if not owed then Alcotest.(check string) "and nothing written" "" bytes)
    [ (99, false); (100, true); (599, true); (600, false); (1000, false) ]

let test_a_target_that_could_split_is_never_written () =
  List.iter
    (fun (meth, target) ->
      let result, bytes =
        written (fun oc -> Write.request_head oc meth ~target [])
      in
      Alcotest.(check bool)
        (Printf.sprintf "%S refused" target)
        true
        (match result with
        | Error `Target -> true
        | Ok () | Error (`Field _) -> false);
      Alcotest.(check string) "and nothing written" "" bytes)
    [
      (`GET, "/a b");
      (`GET, "/a\r\nHost: evil");
      (`GET, "");
      (`Other "GE T", "/");
    ]

(* ------------------------------------------------------------------ *)
(* What the framework owes *)

let test_a_date_is_an_imf_fixdate () =
  List.iter
    (fun (ms, date) -> Alcotest.(check string) date date (Write.date ms))
    [
      (example_instant, example_date);
      (0, "Thu, 01 Jan 1970 00:00:00 GMT");
      (951_782_400_000, "Tue, 29 Feb 2000 00:00:00 GMT");
      (4_102_444_799_999, "Thu, 31 Dec 2099 23:59:59 GMT");
      (* 2100 is not a leap year. *)
      (4_107_542_399_999, "Sun, 28 Feb 2100 23:59:59 GMT");
    ]

let test_a_401_without_a_challenge_is_refused () =
  let code =
    Spindle.Refusal.Code.make "nobody" ~status:`Unauthorized ~doc:"x"
  in
  let route =
    Spindle.get ~refuses:[ code ]
      Spindle.Path.(s "p")
      Spindle.Returns.response
      (Spindle.Dep.return (Error (Spindle.Refusal.make code "Sign in.")))
  in
  Alcotest.(check bool)
    "App.make says no" true
    (Result.is_error (Spindle.App.make [ route ]))

let test_501_comes_before_the_not_found_answer () =
  let app =
    Spindle.Test.app
      ~not_found:(fun _ -> Spindle.Response.make "the not-found answer")
      routes
  in
  Alcotest.(check int)
    "an unknown method" 501
    (Spindle.Test.call app (`Other "PROPFIND") "/anywhere").status;
  Alcotest.(check string)
    "and a known one still reaches it" "the not-found answer"
    (Spindle.Test.call app `GET "/anywhere").body

(* Request.host's order: a trusted proxy's word, then the head's. *)
let test_a_proxy's_host_comes_first () =
  let host ?proxied headers =
    (Spindle.Test.call ?proxied ~headers app `GET "/host").body
  in
  let both = [ ("host", "t"); ("x-forwarded-host", "Front.example") ] in
  Alcotest.(check string)
    "a trusted proxy's" "front.example" (host ~proxied:true both);
  Alcotest.(check string) "anybody else's is not read" "t" (host both);
  Alcotest.(check string)
    "and of a client's line and the proxy's, the proxy's, which is last"
    "front.example"
    (host ~proxied:true
       [
         ("host", "t");
         ("x-forwarded-host", "client.example");
         ("x-forwarded-host", "Front.example");
       ])

(* Test.call is answered as the wire is, HTTP/1.0 included. *)
let test_an_http_1_0_stream_in_process () =
  let r = Spindle.Test.call ~version:Head.Http_1_0 app `GET "/stream" in
  Alcotest.(check string) "the body" "ab" r.body;
  (* The close that ends it is the connection's, which a call in-process
     has none of; the socket row says it. *)
  Alcotest.(check (option string))
    "no coding" None
    (Spindle.Test.header r "transfer-encoding")

(* ------------------------------------------------------------------ *)
(* Generators: well-formed requests of every framing, and mutations of
   them, since random bytes alone almost never reach past a request line. *)

module G = QCheck.Gen

let tchars =
  "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

let gen_token =
  G.(
    string_size ~gen:(oneof_list (List.of_seq (String.to_seq tchars))) (1 -- 8))

let visible_char = G.map Char.chr G.(33 -- 126)

(* A value as a reader answers it: no whitespace at either end, any inside,
   obs-text now and then. *)
let gen_value =
  let inner =
    G.oneof_weighted
      [
        (8, visible_char);
        (1, G.return ' ');
        (1, G.return '\t');
        (1, G.map Char.chr G.(128 -- 255));
      ]
  in
  G.(
    oneof
      [
        return "";
        map2
          (fun first rest -> String.make 1 first ^ rest ^ String.make 1 first)
          visible_char
          (string_size ~gen:inner (0 -- 12));
      ])

let framing_names = [ "content-length"; "transfer-encoding" ]

let gen_field =
  G.(
    pair gen_token gen_value
    |> map (fun (k, v) ->
        if List.mem (String.lowercase_ascii k) framing_names then ("x-" ^ k, v)
        else (k, v)))

let gen_meth =
  G.oneof_list
    [ `GET; `HEAD; `POST; `PUT; `PATCH; `DELETE; `OPTIONS; `Other "PROPFIND" ]

let gen_target =
  G.(map (fun s -> "/" ^ s) (string_size ~gen:visible_char (0 -- 16)))

type body = No_body | Fixed of string | Chunked of string list

let gen_body =
  let text = G.(string_size ~gen:(map Char.chr (0 -- 255)) (1 -- 40)) in
  G.(
    oneof_weighted
      [
        (1, return No_body);
        (2, map (fun s -> Fixed s) text);
        (2, map (fun ps -> Chunked ps) (list_size (1 -- 4) text));
      ])

type message = {
  meth : Meth.t;
  target : string;
  fields : (string * string) list;
  body : body;
}

let gen_message =
  G.(
    map
      (fun (meth, target, fields, body) ->
        { meth; target; fields = ("Host", "t") :: fields; body })
      (quad gen_meth gen_target (list_size (0 -- 5) gen_field) gen_body))

let framing_fields = function
  | No_body -> []
  | Fixed s -> [ ("Content-Length", string_of_int (String.length s)) ]
  | Chunked _ -> [ ("Transfer-Encoding", "chunked") ]

let body_of = function
  | No_body -> ""
  | Fixed s -> s
  | Chunked ps -> String.concat "" ps

let serialise m =
  match
    written (fun oc ->
        let r =
          Write.request_head oc m.meth ~target:m.target
            (m.fields @ framing_fields m.body)
        in
        (match m.body with
        | No_body -> ()
        | Fixed s -> Eio.Buf_write.string oc s
        | Chunked ps ->
            List.iter (Write.chunk oc) ps;
            Write.last_chunk oc);
        r)
  with
  | Ok (), bytes -> bytes
  | Error _, _ -> Alcotest.fail "a generated message the writer refused"

let show_message m = Printf.sprintf "%S" (serialise m)

(* A response, as the writer writes one. A status that has no content is
   given none, and one that may is given a body by any framing, the
   connection's end included. *)
type response_body = Framed of body | To_the_close of string

type response_message = {
  status : Status.t;
  fields : (string * string) list;
  body : response_body;
}

let gen_status =
  G.(oneof [ oneof_list Status.all; map (fun n -> `Code n) (100 -- 599) ])

let no_content status =
  let n = Status.to_int status in
  n < 200 || n = 204 || n = 304

let gen_response =
  G.(
    gen_status >>= fun status ->
    let body =
      if no_content status then return (Framed No_body)
      else
        oneof_weighted
          [
            (3, map (fun b -> Framed b) gen_body);
            ( 1,
              map
                (fun s -> To_the_close s)
                (string_size ~gen:(map Char.chr (0 -- 255)) (0 -- 40)) );
          ]
    in
    map2
      (fun fields body -> { status; fields; body })
      (list_size (0 -- 5) gen_field)
      body)

let serialise_response (m : response_message) =
  let framing =
    match m.body with Framed b -> framing_fields b | To_the_close _ -> []
  in
  match
    written (fun oc ->
        let r = Write.response_head oc m.status (m.fields @ framing) in
        (match m.body with
        | Framed No_body -> ()
        | Framed (Fixed s) | To_the_close s -> Eio.Buf_write.string oc s
        | Framed (Chunked ps) ->
            List.iter (Write.chunk oc) ps;
            Write.last_chunk oc);
        r)
  with
  | Ok (), bytes -> bytes
  | Error _, _ -> Alcotest.fail "a generated response the writer refused"

let show_response_message m = Printf.sprintf "%S" (serialise_response m)

(* A mutation of a message's bytes: the kinds of damage that reach past the
   start line. *)
let dangerous =
  [ '\r'; '\n'; ' '; '\t'; ':'; ','; ';'; '\000'; '0'; 'f'; '\127'; '\255' ]

let mutated gen =
  let open G in
  gen >>= fun s ->
  let n = String.length s in
  let pos = 0 -- (n - 1) in
  let byte =
    oneof_weighted [ (3, oneof_list dangerous); (1, map Char.chr (0 -- 255)) ]
  in
  let insert =
    map2
      (fun i c -> String.sub s 0 i ^ String.make 1 c ^ String.sub s i (n - i))
      pos byte
  in
  let drop =
    map (fun i -> String.sub s 0 i ^ String.sub s (i + 1) (n - i - 1)) pos
  in
  let flip =
    map2
      (fun i c -> String.mapi (fun j c' -> if j = i then c else c') s)
      pos byte
  in
  let fold =
    (* A line folded: whitespace after a line's end. *)
    map2
      (fun i ws ->
        match find_from s i "\r\n" with
        | Some j when j + 2 < n ->
            String.sub s 0 (j + 2) ^ ws ^ String.sub s (j + 2) (n - j - 2)
        | Some _ | None -> s)
      pos
      (oneof_list [ " "; "\t" ])
  in
  let relength =
    (* A declared length or a chunk size, changed. *)
    map
      (fun k ->
        match find_from s 0 "Content-Length: " with
        | Some j ->
            let start = j + 16 in
            let stop =
              match find_from s start "\r\n" with Some e -> e | None -> n
            in
            String.sub s 0 start ^ k ^ String.sub s stop (n - stop)
        | None -> (
            match find_from s 0 "\r\n\r\n" with
            | Some j when j + 4 < n ->
                let start = j + 4 in
                let stop =
                  match find_from s start "\r\n" with Some e -> e | None -> n
                in
                String.sub s 0 start ^ k ^ String.sub s stop (n - stop)
            | Some _ | None -> s))
      (oneof_list
         [
           "0";
           "1";
           "3";
           "ff";
           "+5";
           "05";
           "-1";
           "5, 6";
           "99999999999999999999";
           "0x5";
           " 5";
           "";
         ])
  in
  oneof_weighted
    [
      (3, insert); (2, drop); (3, flip); (1, fold); (2, relength); (1, return s);
    ]

let gen_mutated = mutated (G.map serialise gen_message)
let gen_mutated_response = mutated (G.map serialise_response gen_response)

(* ------------------------------------------------------------------ *)
(* The properties *)

let within_eio f x = Eio_mock.Backend.run (fun () -> f x)

let test_writing_then_reading_is_the_identity =
  QCheck.Test.make ~count:1000 ~name:"writing then reading is the identity"
    (QCheck.make ~print:show_message gen_message)
    (within_eio (fun m ->
         match read ~max:65536 ~max_body:65536 Whole (serialise m) with
         | Read (h, body) ->
             Meth.equal h.meth m.meth
             && String.equal h.target m.target
             && String.equal (version_name h.version) "1.1"
             && List.equal
                  (fun (a, b) (c, d) -> String.equal a c && String.equal b d)
                  h.headers
                  (m.fields @ framing_fields m.body)
             && String.equal body (body_of m.body)
         | got -> QCheck.Test.fail_report (show got)))

let gen_cuts n = G.(list_size (0 -- 6) (0 -- n))

let test_read_boundaries_change_nothing =
  let gen =
    G.(
      gen_mutated >>= fun s ->
      map (fun cuts -> (s, cuts)) (gen_cuts (String.length s)))
  in
  QCheck.Test.make ~count:2000 ~name:"read boundaries change nothing"
    (QCheck.make
       ~print:(fun (s, cuts) ->
         Printf.sprintf "%S %s" s (delivery_name (At cuts)))
       gen)
    (within_eio (fun (s, cuts) ->
         let whole = show (read Whole s) in
         let cut = show (read (At cuts) s) in
         let bytewise = show (read Bytewise s) in
         (String.equal whole cut && String.equal whole bytewise)
         || QCheck.Test.fail_reportf "whole: %s\ncut: %s\nbytewise: %s" whole
              cut bytewise))

(* Every row of the table, at cuts a generator chooses. *)
let test_every_row_holds_at_any_cut () =
  let arb rows =
    QCheck.make
      ~print:(fun (i, cuts) ->
        let (r : row) = rows.(i) in
        Printf.sprintf "%s: %s, %s" r.rfc r.says (delivery_name (At cuts)))
      G.(
        int_bound (Array.length rows - 1) >>= fun i ->
        map (fun cuts -> (i, cuts)) (gen_cuts (String.length rows.(i).bytes)))
  in
  let readers = Array.of_list (heads @ bodies) in
  let server = Array.of_list (server @ attacks) in
  QCheck.Test.check_exn
    (QCheck.Test.make ~count:500 ~name:"a reading row, at any cut" (arb readers)
       (within_eio (fun (i, cuts) ->
            check_reading readers.(i) (At cuts);
            true)));
  let responses = Array.of_list responses in
  QCheck.Test.check_exn
    (QCheck.Test.make ~count:500 ~name:"a response row, at any cut"
       (QCheck.make
          ~print:(fun (i, cuts) ->
            let (r : response_row) = responses.(i) in
            Printf.sprintf "%s: %s, %s" r.rfc r.says (delivery_name (At cuts)))
          G.(
            int_bound (Array.length responses - 1) >>= fun i ->
            map
              (fun cuts -> (i, cuts))
              (gen_cuts (String.length responses.(i).bytes))))
       (within_eio (fun (i, cuts) ->
            check_response responses.(i) (At cuts);
            true)));
  ( In_memory.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let connect = serve ~sw env in
    QCheck.Test.check_exn
      (QCheck.Test.make ~count:100 ~name:"a server row, at any cut" (arb server)
         (fun (i, cuts) ->
           check_answers env connect server.(i) (At cuts);
           true)) );
  (* A client row's cuts fall in each answer the server writes. *)
  Eio_main.run @@ fun env ->
  let clients = Array.of_list client_rows in
  QCheck.Test.check_exn
    (QCheck.Test.make ~count:40 ~name:"a client row, at any cut"
       (QCheck.make
          ~print:(fun (i, cuts) ->
            Printf.sprintf "%s, %s"
              (client_row_name clients.(i))
              (delivery_name (At cuts)))
          G.(
            int_bound (Array.length clients - 1) >>= fun i ->
            map (fun cuts -> (i, cuts)) (gen_cuts 120)))
       (fun (i, cuts) ->
         match run_client_row env clients.(i) (At cuts) with
         | Ok () -> true
         | Error why -> QCheck.Test.fail_report why))

let test_writing_then_reading_a_response_is_the_identity =
  QCheck.Test.make ~count:1000
    ~name:"writing then reading a response is the identity"
    (QCheck.make ~print:show_response_message gen_response)
    (within_eio (fun m ->
         let bytes = serialise_response m in
         match
           read_response ~max:65536 ~max_body:65536 ~meth:`GET Whole bytes
         with
         | Response_read (h, body) ->
             let framing =
               match m.body with
               | Framed b -> framing_fields b
               | To_the_close _ -> []
             in
             Status.equal h.status m.status
             && String.equal h.reason (Status.reason m.status)
             && String.equal (version_name h.version) "1.1"
             && List.equal
                  (fun (a, b) (c, d) -> String.equal a c && String.equal b d)
                  h.headers (m.fields @ framing)
             && String.equal body
                  (match m.body with
                  | Framed b -> body_of b
                  | To_the_close s -> s)
         | got -> QCheck.Test.fail_report (show_response got)))

(* Whatever the writer accepts, the reader reads as it was written: a field of
   any bytes at all, not only the generated valid ones. *)
let test_what_the_writer_accepts_is_read =
  let byte = G.(map Char.chr (0 -- 255)) in
  let trimmed v =
    let ows c = Char.equal c ' ' || Char.equal c '\t' in
    let n = String.length v in
    let rec first i = if i < n && ows v.[i] then first (i + 1) else i in
    let rec last j = if j > 0 && ows v.[j - 1] then last (j - 1) else j in
    let i = first 0 and j = last n in
    if j <= i then "" else String.sub v i (j - i)
  in
  QCheck.Test.make ~count:5000 ~name:"what the writer accepts, the reader reads"
    (QCheck.make
       ~print:QCheck.Print.(pair string string)
       G.(
         pair (string_size ~gen:byte (0 -- 6)) (string_size ~gen:byte (0 -- 12))))
    (within_eio (fun (name, value) ->
         let name =
           if List.mem (String.lowercase_ascii name) framing_names then
             "x-" ^ name
           else name
         in
         match
           written (fun oc ->
               Write.response_head oc `OK
                 [ (name, value); ("content-length", "0") ])
         with
         | Error _, bytes -> String.equal bytes ""
         | Ok (), bytes -> (
             match
               read_response ~max:65536 ~max_body:65536 ~meth:`GET Whole bytes
             with
             | Response_read (h, _) ->
                 List.exists
                   (fun (k, v) ->
                     String.equal k name && String.equal v (trimmed value))
                   h.headers
             | got -> QCheck.Test.fail_report (show_response got))))

let test_response_read_boundaries_change_nothing =
  let gen =
    G.(
      gen_mutated_response >>= fun s ->
      map (fun cuts -> (s, cuts)) (gen_cuts (String.length s)))
  in
  QCheck.Test.make ~count:2000
    ~name:"a response's read boundaries change nothing"
    (QCheck.make
       ~print:(fun (s, cuts) ->
         Printf.sprintf "%S %s" s (delivery_name (At cuts)))
       gen)
    (within_eio (fun (s, cuts) ->
         let read d = show_response (read_response ~meth:`GET d s) in
         let whole = read Whole and cut = read (At cuts) in
         let bytewise = read Bytewise in
         (String.equal whole cut && String.equal whole bytewise)
         || QCheck.Test.fail_reportf "whole: %s\ncut: %s\nbytewise: %s" whole
              cut bytewise))

(* After a head read within its limit: a body read within its own, and a
   declared length past it refused without a byte of it read. *)
let body_within_limits ic framing ~max ~max_body =
  let before = Eio.Buf_read.consumed_bytes ic in
  let r = Framing.reader framing ic ~max_trailer:max in
  match Framing.read r ~max:max_body ~reserve:(fun _ -> true) with
  | Ok body -> String.length body <= max_body
  | Error `Too_large -> (
      match framing with
      | Framing.Fixed _ -> Eio.Buf_read.consumed_bytes ic = before
      | Framing.No_body | Framing.Chunked | Framing.Until_close -> true)
  | Error (`Broken _ | `Busy) -> true

let head_within ic ~max =
  Eio.Buf_read.consumed_bytes ic <= max
  || QCheck.Test.fail_reportf "a head of %d bytes read under a limit of %d"
       (Eio.Buf_read.consumed_bytes ic)
       max

(* Small limits, so the mutations reach them. *)
let test_no_input_crashes_hangs_or_reads_past_a_limit =
  let max = 128 and max_body = 16 in
  QCheck.Test.make ~count:5000
    ~name:"no input crashes, hangs or reads past a limit"
    (QCheck.make ~print:(Printf.sprintf "%S") gen_mutated)
    (within_eio (fun s ->
         let ic =
           Eio.Buf_read.of_flow ~initial_size:16 ~max_size:max (source [ s ])
         in
         match Head.Request.read ~max ic with
         | Error _ -> true
         | Ok head -> (
             head_within ic ~max
             &&
             match Framing.of_request head with
             | Error _ -> true
             | Ok framing -> body_within_limits ic framing ~max ~max_body)))

let test_no_response_crashes_hangs_or_reads_past_a_limit =
  let max = 128 and max_body = 16 in
  QCheck.Test.make ~count:5000
    ~name:"no response crashes, hangs or reads past a limit"
    (QCheck.make ~print:(Printf.sprintf "%S") gen_mutated_response)
    (within_eio (fun s ->
         let ic =
           Eio.Buf_read.of_flow ~initial_size:16 ~max_size:max (source [ s ])
         in
         match Head.Response.read ~max ic with
         | Error _ -> true
         | Ok head -> (
             head_within ic ~max
             &&
             match Framing.of_response ~request_meth:`GET head with
             | Error _ -> true
             | Ok framing -> body_within_limits ic framing ~max ~max_body)))

(* A request of a sequence sent down one connection, and what it is owed. *)
type step =
  | Get of string
  | Read_body of string * body
  | Ignore_body of string * body
  | Too_big of string
  | Unframable
  | Close of string
  | Frames_itself of string
      (** a handler writing a field only the server may *)
  | Closing  (** an answer that asks to be its connection's last *)

let gen_id =
  G.(
    string_size
      ~gen:(oneof_list (List.of_seq (String.to_seq "abcdefghij")))
      (1 -- 6))

(* Bodies that are themselves requests, so a body answered as one shows. *)
let gen_smuggling_body =
  let text =
    G.oneof_list
      [ smuggled; "GET /id/x HTTP/1.1\r\n\r\n"; "0\r\n\r\n"; "hello" ]
  in
  G.(
    oneof
      [
        map (fun s -> Fixed s) text;
        map (fun ps -> Chunked ps) (list_size (1 -- 3) text);
      ])

let gen_step =
  G.(
    oneof_weighted
      [
        (3, map (fun i -> Get i) gen_id);
        (3, map2 (fun i b -> Read_body (i, b)) gen_id gen_smuggling_body);
        (3, map2 (fun i b -> Ignore_body (i, b)) gen_id gen_smuggling_body);
        (1, map (fun i -> Too_big i) gen_id);
        (1, return Unframable);
        (1, map (fun i -> Close i) gen_id);
        ( 2,
          map
            (fun f -> Frames_itself f)
            (oneof_list
               [
                 "content-length";
                 "Transfer-Encoding";
                 "connection";
                 "keep-alive";
                 "upgrade";
                 "te";
                 "trailer";
               ]) );
        (1, return Closing);
      ])

let framed path body =
  let m = { meth = `POST; target = path; fields = [ ("Host", "t") ]; body } in
  serialise m

let bytes_of = function
  | Get i -> get ("/id/" ^ i)
  | Read_body (i, b) -> framed ("/read/" ^ i) b
  | Ignore_body (i, b) -> framed ("/ignore/" ^ i) b
  | Too_big i ->
      post ("/read/" ^ i)
        (String.make (max_body_on_the_server + 1) 'x' ^ smuggled)
  | Unframable ->
      request ~line:"POST /read/u HTTP/1.1" ~body:("0\r\n\r\n" ^ smuggled)
        [ "Host: t"; "Content-Length: 5"; "Transfer-Encoding: chunked" ]
  | Close i ->
      request
        ~line:("GET /id/" ^ i ^ " HTTP/1.1")
        [ "Host: t"; "Connection: close" ]
  | Frames_itself field -> get ("/sets/" ^ field)
  | Closing -> get "/close"

(* What each step is answered, and whether the connection ends there. *)
let owed = function
  | Get i | Ignore_body (i, _) -> ((200, Some i), false)
  | Read_body (_, b) when String.length (body_of b) > max_body_on_the_server ->
      ((413, None), false)
  | Read_body (i, b) -> ((200, Some (i ^ "=" ^ body_of b)), false)
  | Too_big _ -> ((413, None), false)
  | Unframable -> ((400, None), true)
  | Close i -> ((200, Some i), true)
  | Frames_itself _ -> ((500, None), false)
  | Closing -> ((200, Some "bye"), true)

let show_step s = Printf.sprintf "%S" (bytes_of s)

let test_every_request_is_answered_once_in_order () =
  In_memory.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let connect = serve ~sw env in
  QCheck.Test.check_exn
    (QCheck.Test.make ~count:1000
       ~name:"every request is answered once, in order, as itself"
       (QCheck.make
          ~print:QCheck.Print.(list show_step)
          G.(list_size (1 -- 6) gen_step))
       (fun steps ->
         (* Answered up to and including the first that ends the connection;
            nothing after it, and nothing more at all. *)
         let rec expected = function
           | [] -> []
           | s :: rest -> (
               match owed s with
               | a, true -> [ a ]
               | a, false -> a :: expected rest)
         in
         let expected = expected steps in
         let bytes = String.concat "" (List.map bytes_of steps) in
         let got =
           Eio.Switch.run @@ fun sw ->
           let flow = connect ~sw in
           let r =
             Eio.Buf_read.of_flow ~max_size:1_000_000
               (In_memory.at_once ~clock:(Eio.Stdenv.mono_clock env) flow)
           in
           Eio.Flow.copy_string bytes flow;
           (* Nothing more is coming, so a server that finished answers
              closes too, and whatever it sends before that is counted. *)
           (try Eio.Flow.shutdown flow `Send with Eio.Io _ -> ());
           let rec answers acc =
             if at_end r then List.rev acc
             else answers ((read_answer ~head:false r : answered) :: acc)
           in
           answers []
         in
         List.length got = List.length expected
         && List.for_all2
              (fun (status, body) (a : answered) ->
                a.status = status
                &&
                match body with
                | Some b -> String.equal b a.body
                | None -> true)
              expected got
         || QCheck.Test.fail_reportf "owed %s\ngot %s"
              (String.concat ", "
                 (List.map
                    (fun (s, b) ->
                      Printf.sprintf "%d %s" s (Option.value b ~default:"_"))
                    expected))
              (String.concat ", "
                 (List.map
                    (fun (a : answered) ->
                      Printf.sprintf "%d %S" a.status a.body)
                    got))))

(* ------------------------------------------------------------------ *)
(* The referee *)

(* A verdict both parsers can give: the head, or no head. The start line is
   its words: a method, a target and a version, or a version, a code and a
   reason. *)
type verdict =
  | Accepted of {
      start : string list;
      headers : (string * string) list;
      framing : string;
    }
  | Refused_it

let show_verdict = function
  | Refused_it -> "refused"
  | Accepted v ->
      Printf.sprintf "%s [%s] %s"
        (String.concat " " (List.map (Printf.sprintf "%S") v.start))
        (String.concat "; "
           (List.map (fun (k, v) -> Printf.sprintf "%S: %S" k v) v.headers))
        v.framing

let framing_name = function
  | Ok Framing.No_body -> "fixed 0"
  | Ok (Framing.Fixed n) -> Printf.sprintf "fixed %d" n
  | Ok Framing.Chunked -> "chunked"
  | Ok Framing.Until_close -> "to the close"
  | Error () -> "refused"

let ours s =
  let ic = Eio.Buf_read.of_flow ~max_size:65536 (source [ s ]) in
  match Head.Request.read ~max:65536 ic with
  | Error _ -> Refused_it
  | Ok h ->
      Accepted
        {
          start = [ Meth.to_string h.meth; h.target; version_name h.version ];
          headers = h.headers;
          framing =
            framing_name (Result.map_error ignore (Framing.of_request h));
        }

let theirs s =
  match
    Angstrom.parse_string ~consume:Angstrom.Consume.Prefix
      Httpun.Httpun_private.Parse.request s
  with
  | Error _ -> Refused_it
  | Ok r ->
      Accepted
        {
          start =
            [
              Httpun.Method.to_string r.meth;
              r.target;
              Printf.sprintf "%d.%d" r.version.major r.version.minor;
            ];
          headers = Httpun.Headers.to_list r.headers;
          framing =
            (match Httpun.Request.body_length r with
            | `Fixed n -> Printf.sprintf "fixed %Ld" n
            | `Chunked -> "chunked"
            | `Error _ -> "refused");
        }

(* A response, as answering a GET. *)
let ours_response s =
  let ic = Eio.Buf_read.of_flow ~max_size:65536 (source [ s ]) in
  match Head.Response.read ~max:65536 ic with
  | Error _ -> Refused_it
  | Ok h ->
      Accepted
        {
          start =
            [
              version_name h.version;
              string_of_int (Status.to_int h.status);
              h.reason;
            ];
          headers = h.headers;
          framing =
            framing_name
              (Result.map_error ignore
                 (Framing.of_response ~request_meth:`GET h));
        }

let theirs_response s =
  match
    Angstrom.parse_string ~consume:Angstrom.Consume.Prefix
      Httpun.Httpun_private.Parse.response s
  with
  (* httpun raises on a code below 100 from inside its parser: its way of
     refusing one. *)
  | exception Failure _ -> Refused_it
  | Error _ -> Refused_it
  | Ok r ->
      Accepted
        {
          start =
            [
              Printf.sprintf "%d.%d" r.version.major r.version.minor;
              string_of_int (Httpun.Status.to_code r.status);
              r.reason;
            ];
          headers = Httpun.Headers.to_list r.headers;
          framing =
            (match Httpun.Response.body_length ~request_method:`GET r with
            | `Fixed n -> Printf.sprintf "fixed %Ld" n
            | `Chunked -> "chunked"
            | `Close_delimited -> "to the close"
            | `Error _ -> "refused");
        }

(* The head as httpun would take it: up to its first empty line. *)
let head_of s =
  match find_from s 0 "\r\n\r\n" with
  | Some i -> String.sub s 0 (i + 4)
  | None -> s

let lines s = split_on s "\r\n"

let control_in s =
  let n = String.length s in
  let rec at i =
    i < n
    &&
    let c = s.[i] in
    (Char.code c < 0x20 && not (Char.equal c '\t'))
    && (not (Char.equal c '\r' && i + 1 < n && Char.equal s.[i + 1] '\n'))
    && not (Char.equal c '\n' && i > 0 && Char.equal s.[i - 1] '\r')
    || Char.code c = 0x7f
    || at (i + 1)
  in
  at 0

let request_line s = match lines (head_of s) with l :: _ -> l | [] -> ""
let words s = String.split_on_char ' ' (request_line s)
let field_lines s = match lines (head_of s) with _ :: fs -> fs | [] -> []

let named name s =
  List.exists
    (fun l ->
      match String.index_opt l ':' with
      | Some i -> String.equal (String.lowercase_ascii (String.sub l 0 i)) name
      | None -> false)
    (field_lines s)

let digits v =
  String.length v > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) v

let values name s =
  List.filter_map
    (fun l ->
      match String.index_opt l ':' with
      | Some i
        when String.equal (String.lowercase_ascii (String.sub l 0 i)) name ->
          Some (String.trim (String.sub l (i + 1) (String.length l - i - 1)))
      | Some _ | None -> None)
    (field_lines s)

(* Which way a listed difference goes: we refuse what httpun takes, or the
   two read one head as two different ones. A difference that goes the
   other way from its entry is not explained by it. *)
type difference = {
  why : string;
  we : [ `Refuse | `Read_it_otherwise ];
  applies : string -> bool;
}

(* Where the two read a head's fields differently on purpose: the same for
   a request and a response, since both readers share one field grammar. *)
let field_differences =
  [
    {
      why =
        "a bare LF: RFC 9112 §2.2 lets a recipient end a line with one, and \
         httpun reads it as part of the line";
      we = `Read_it_otherwise;
      applies =
        (fun s ->
          List.exists (fun l -> String.contains l '\n') (lines (head_of s)));
    };
    {
      why =
        "a control character, or DEL: RFC 9110 §5.5 lets a recipient refuse \
         one, and httpun keeps it in a name, a value or the request line";
      we = `Refuse;
      applies = (fun s -> control_in (head_of s));
    };
    {
      why =
        "a field name that is not a token: RFC 9110 §5.1 makes it one, and \
         httpun takes anything before a colon, nothing included";
      we = `Refuse;
      applies =
        (fun s ->
          List.exists
            (fun l ->
              match String.index_opt l ':' with
              | Some i ->
                  let name = String.sub l 0 i in
                  (not (Field.is_token name))
                  && not
                       (String.length name > 0
                       && (Char.equal name.[0] ' ' || Char.equal name.[0] '\t')
                       )
              | None -> false)
            (field_lines s));
    };
    {
      why =
        "a Content-Length that is not digits: RFC 9110 §8.6 makes it digits, \
         and httpun reads it with Int64.of_string, which takes 0x5, +5 and 5_0";
      we = `Refuse;
      applies =
        (fun s ->
          List.exists
            (fun v ->
              not
                (List.for_all digits
                   (List.map String.trim (String.split_on_char ',' v))))
            (values "content-length" s));
    };
    {
      why =
        "a list of identical lengths: RFC 9112 §6.3 lets a recipient take 5, 5 \
         as one length, and httpun reads the whole value as one number";
      we = `Read_it_otherwise;
      applies =
        (fun s ->
          List.exists
            (fun v -> String.contains v ',')
            (values "content-length" s));
    };
    {
      why =
        "an empty element in Transfer-Encoding: RFC 9110 §5.6.1.2 has it \
         ignored, and httpun reads the whole value as one coding";
      we = `Read_it_otherwise;
      applies =
        (fun s ->
          List.exists
            (fun v -> String.contains v ',')
            (values "transfer-encoding" s));
    };
    {
      why =
        "Transfer-Encoding in two fields: one list, RFC 9110 §5.3, so chunked \
         twice is 400 and anything after it 400, where httpun reads the last";
      we = `Refuse;
      applies = (fun s -> List.length (values "transfer-encoding" s) > 1);
    };
    {
      why =
        "both framings: RFC 9112 §6.1 lets a server refuse them, the one \
         reading nobody can mistake, and httpun believes Transfer-Encoding";
      we = `Refuse;
      applies =
        (fun s -> named "transfer-encoding" s && named "content-length" s);
    };
  ]

(* Every place Spindle reads a request's head differently from httpun on
   purpose, and why. Anything else the two disagree about fails the suite. *)
let request_differences =
  [
    {
      why =
        "an empty line before the request line: RFC 9112 §2.2 asks a server to \
         ignore it, and httpun reads it as the method";
      we = `Read_it_otherwise;
      applies =
        (fun s ->
          String.length s > 0 && (Char.equal s.[0] '\r' || Char.equal s.[0] '\n'));
    };
    {
      why =
        "a method that is not a token: RFC 9112 §3 makes it one, and httpun \
         takes anything before a space";
      we = `Refuse;
      applies =
        (fun s ->
          match words s with m :: _ -> not (Field.is_token m) | [] -> false);
    };
    {
      why =
        "a target that is empty or not visible ASCII: RFC 9112 §3.2 has no \
         form for either, and httpun takes whatever is between two spaces";
      we = `Refuse;
      applies =
        (fun s ->
          match words s with
          | _ :: t :: _ ->
              String.equal t ""
              || String.exists
                   (fun c -> Char.code c <= 0x20 || Char.code c >= 0x7f)
                   t
          | _ -> false);
    };
    {
      why =
        "a version other than HTTP/1.0 and HTTP/1.1: this server speaks those, \
         and httpun reads any HTTP/d.d";
      we = `Refuse;
      applies =
        (fun s ->
          match words s with
          | [ _; _; v ] -> not (List.mem v [ "HTTP/1.0"; "HTTP/1.1" ])
          | _ -> false);
    };
    {
      why =
        "a request with no Host, two, or one that is not a host: RFC 9112 §3.2 \
         owes it a 400, and httpun reads no Host at all";
      we = `Refuse;
      applies =
        (fun s ->
          let hosts = values "host" s in
          (* httpun reads no Host, so any but a plain one -- a name and
             perhaps a port -- is one it takes and this reader may not; the
             rows say which of those are hosts. *)
          let host h =
            let name, port =
              match String.index_opt h ':' with
              | Some c ->
                  ( String.sub h 0 c,
                    String.sub h (c + 1) (String.length h - c - 1) )
              | None -> (h, "0")
            in
            String.length name > 0
            && String.for_all
                 (function
                   | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' -> true
                   | _ -> false)
                 name
            && digits port
          in
          List.length hosts <> 1
          && not
               (match words s with [ _; _; "HTTP/1.0" ] -> true | _ -> false)
          || List.length hosts > 1
          || List.exists (fun h -> not (host h)) hosts);
    };
    {
      why =
        "a target that is not a path: RFC 9112 §3.2 gives each other form to \
         one method, or has it name an authority, and httpun reads any";
      we = `Refuse;
      applies =
        (fun s ->
          match words s with
          | _ :: t :: _ -> not (String.starts_with ~prefix:"/" t)
          | _ -> false);
    };
    {
      why =
        "a later HTTP/1 minor version: RFC 9110 §6.2 has a server answer it as \
         its own, HTTP/1.1, and httpun reads the number it was sent";
      we = `Read_it_otherwise;
      applies =
        (fun s ->
          match words s with
          | [ _; _; v ] ->
              String.length v = 8
              && String.starts_with ~prefix:"HTTP/1." v
              && not (List.mem v [ "HTTP/1.0"; "HTTP/1.1" ])
          | _ -> false);
    };
  ]
  @ field_differences

(* A status line's version, and what follows its first space. *)
let status_words s =
  let l = request_line s in
  match String.index_opt l ' ' with
  | Some i -> (String.sub l 0 i, String.sub l (i + 1) (String.length l - i - 1))
  | None -> (l, "")

let http_1 v = String.length v = 8 && String.starts_with ~prefix:"HTTP/1." v

(* And a response's. *)
let response_differences =
  [
    {
      why =
        "an obsolete fold: RFC 9112 §5.2 has a user agent join it onto the \
         field before, and httpun refuses it";
      we = `Read_it_otherwise;
      applies =
        (fun s ->
          List.exists
            (fun l ->
              String.length l > 0
              && (Char.equal l.[0] ' ' || Char.equal l.[0] '\t'))
            (field_lines s));
    };
    {
      why =
        "a status line with no space after its code: nothing turns on the \
         reason, and httpun needs the space";
      we = `Read_it_otherwise;
      applies =
        (fun s ->
          let _, rest = status_words s in
          String.length rest = 3);
    };
    {
      why =
        "a version other than HTTP/1.x: this reader speaks HTTP/1, and httpun \
         reads any HTTP/d.d";
      we = `Refuse;
      applies =
        (fun s ->
          let v, _ = status_words s in
          not (http_1 v));
    };
    {
      why =
        "a later HTTP/1 minor version: RFC 9110 §6.2 has it read as HTTP/1.1, \
         and httpun reads the number it was sent";
      we = `Read_it_otherwise;
      applies =
        (fun s ->
          let v, _ = status_words s in
          http_1 v && not (List.mem v [ "HTTP/1.0"; "HTTP/1.1" ]));
    };
    {
      why =
        "a status code above 599: RFC 9110 §15 has none, and httpun reads any \
         three digits";
      we = `Refuse;
      applies =
        (fun s ->
          let _, rest = status_words s in
          String.length rest >= 3
          && digits (String.sub rest 0 3)
          && int_of_string (String.sub rest 0 3) > 599);
    };
    {
      why =
        "a transfer coding other than chunked: nothing here decodes one, and \
         httpun reads the body to the close";
      we = `Refuse;
      applies =
        (fun s ->
          List.exists
            (fun v -> not (String.equal (String.lowercase_ascii v) "chunked"))
            (values "transfer-encoding" s));
    };
  ]
  @ field_differences

let refused = function
  | Refused_it -> true
  | Accepted { framing; _ } -> String.equal framing "refused"

let explained differences s ours =
  List.exists
    (fun d ->
      d.applies s
      && match d.we with `Refuse -> refused ours | `Read_it_otherwise -> true)
    differences

let referee ~name ~differences gen ours theirs =
  QCheck.Test.make ~count:5000 ~name
    (QCheck.make ~print:(Printf.sprintf "%S") gen)
    (within_eio (fun s ->
         let a = ours s and b = theirs s in
         String.equal (show_verdict a) (show_verdict b)
         || explained differences s a
         || QCheck.Test.fail_reportf "we read %s\nhttpun read %s%s"
              (show_verdict a) (show_verdict b)
              (String.concat ""
                 (List.filter_map
                    (fun d ->
                      if d.applies s then
                        Some ("\nlisted, the other way: " ^ d.why)
                      else None)
                    differences))))

let test_the_referee_agrees_where_nothing_is_listed =
  referee ~name:"httpun reads every request's head as we do, but where listed"
    ~differences:request_differences gen_mutated ours theirs

let test_the_referee_agrees_on_responses_where_nothing_is_listed =
  referee ~name:"httpun reads every response's head as we do, but where listed"
    ~differences:response_differences gen_mutated_response ours_response
    theirs_response

(* ------------------------------------------------------------------ *)
(* Field values *)

(* A value's structure, as RFC 9110 §5.6 and the sections built on it write
   it: a row each, the value and what it must read as -- or that it is
   refused. A value is a string already in hand, so it is read whole. *)

module Media_type = Spindle_http.Media_type

type value_row =
  | Value : {
      rfc : string;
      says : string;
      parse : string -> ('a, string) result;
      show : 'a -> string;
      value : string;
      owes : string option;  (** what it reads as, shown; [None] refused *)
    }
      -> value_row

let show_media (m : Media_type.t) =
  m.type_ ^ "/" ^ m.subtype
  ^ String.concat ""
      (List.map (fun (n, v) -> ";" ^ n ^ "=[" ^ v ^ "]") m.parameters)

let media rfc says value owes =
  Value { rfc; says; parse = Media_type.parse; show = show_media; value; owes }

let elements rfc says value owes =
  Value
    {
      rfc;
      says;
      parse = (fun v -> Ok (Field.elements v));
      show = (fun es -> String.concat " | " es);
      value;
      owes = Some owes;
    }

let field_values =
  [
    media "9110 §5.6.4" "a quoted string's escapes are undone"
      {|text/plain; a="b\"c\\d"|} (Some {|text/plain;a=[b"c\d]|});
    media "9110 §5.6.4" "a quoted string holds a ; and a ,"
      {|text/plain; a="1;2,3"|} (Some "text/plain;a=[1;2,3]");
    media "9110 §5.6.4" "a quoted string that does not end is refused"
      {|text/plain; a="open|} None;
    media "9110 §5.6.4" "a control character in a quoted string is refused"
      "text/plain; a=\"a\x01b\"" None;
    media "9110 §5.6.6" "a parameter's name is compared without case"
      "text/plain; CharSet=utf-8" (Some "text/plain;charset=[utf-8]");
    media "9110 §5.6.6" "whitespace may stand around the semicolon"
      "text/plain ;charset=utf-8" (Some "text/plain;charset=[utf-8]");
    media "9110 §5.6.6" "an empty parameter is passed over"
      "text/plain;;charset=utf-8" (Some "text/plain;charset=[utf-8]");
    media "6838 §4.3" "a parameter given twice is refused"
      "text/plain; charset=a; CHARSET=b" None;
    media "9110 §5.6.6" "no whitespace stands around the equals sign"
      "text/plain; charset = utf-8" None;
    media "9110 §8.3.1" "the type and subtype are compared without case"
      "Application/JSON" (Some "application/json");
    media "9110 §8.3.1" "no whitespace stands around the slash" "text / plain"
      None;
    media "9110 §8.3.1" "a type with no subtype is refused" "text" None;
    elements "9110 §5.6.1" "a list is not split inside a quoted string"
      {|"a,b", c|} {|"a,b" | c|};
    elements "9110 §5.6.1" "an escaped quote does not end a quoted string"
      {|"a\",b", c|} {|"a\",b" | c|};
    elements "9110 §5.6.1" "empty elements are passed over" "a, , b," "a | b";
  ]

let value_case (Value r) =
  Alcotest.test_case
    (r.rfc ^ ": " ^ r.says)
    `Quick
    (fun () ->
      Alcotest.(check (option string))
        r.value r.owes
        (Result.to_option (Result.map r.show (r.parse r.value))))

type Eio.Exn.Backend.t += Reset_by_the_test

(* A connection that fails under a head is the peer leaving, answered as a
   value at both ends, never an exception across the interface. *)
let test_a_connection_failing_under_a_head_is_a_value () =
  let reset = Eio.Net.err (Connection_reset Reset_by_the_test) in
  let reader pieces =
    Eio.Buf_read.of_flow ~max_size:max_head (source ~ends:reset pieces)
  in
  let request pieces =
    match Head.Request.read ~max:max_head (reader pieces) with
    | Error Head.Closed -> "closed"
    | Error (Head.Refused _) -> "refused"
    | Ok _ -> "read"
  and response pieces =
    match Head.Response.read ~max:max_head (reader pieces) with
    | Error `Closed -> "closed"
    | Error (`Malformed _) -> "malformed"
    | Ok _ -> "read"
  in
  Alcotest.(check string) "a request, before a byte" "closed" (request []);
  Alcotest.(check string)
    "a request, after its start line" "closed"
    (request [ "GET / HTTP/1.1\r\n" ]);
  Alcotest.(check string) "a response, before a byte" "closed" (response []);
  Alcotest.(check string)
    "a response, after its status line" "malformed"
    (response [ "HTTP/1.1 200 OK\r\n" ])

(* What a printer writes, its parser reads back as itself: a value that is
   no token is quoted, its quote and backslash escaped. *)
let test_a_printed_media_type_reads_back () =
  let m =
    {
      Media_type.type_ = "text";
      subtype = "plain";
      parameters = [ ("charset", "utf-8"); ("note", {|a "b"; c\d|}) ];
    }
  in
  Alcotest.(check (option string))
    "read back"
    (Some (show_media m))
    (Result.to_option
       (Result.map show_media
          (Result.bind (Media_type.to_string m) Media_type.parse)))

(* A JSON route refuses a Content-Type that is no media type before it
   reads the body, as it refuses one that is not JSON. *)
let test_a_malformed_media_type_is_refused () =
  let route =
    Spindle.post
      Spindle.Path.(s "echo")
      (Spindle.Returns.json Wiretype.string)
      (let+ s = Spindle.json Wiretype.string in
       Ok s)
  in
  let app = Spindle.Test.app [ route ] in
  let status content_type =
    (Spindle.Test.call app `POST "/echo" ~body:{|"hi"|}
       ~headers:[ ("content-type", content_type) ])
      .status
  in
  Alcotest.(check int)
    "json, with a charset" 200
    (status "application/json; charset=utf-8");
  Alcotest.(check int)
    "a parameter with no name" 415
    (status "application/json; =");
  Alcotest.(check int) "no subtype" 415 (status "application")

module Auth = Spindle_http.Auth

let show_auth (a : Auth.t) =
  a.scheme
  ^
  match a.value with
  | Auth.Token68 t -> " " ^ t
  | Auth.Params ps ->
      " {"
      ^ String.concat "; " (List.map (fun (n, v) -> n ^ "=[" ^ v ^ "]") ps)
      ^ "}"

let credentials rfc says value owes =
  Value { rfc; says; parse = Auth.credentials; show = show_auth; value; owes }

let challenges rfc says value owes =
  Value
    {
      rfc;
      says;
      parse = Auth.challenges;
      show = (fun cs -> String.concat " | " (List.map show_auth cs));
      value;
      owes;
    }

let auth_values =
  [
    credentials "9110 §11.2" "a parameter given twice is refused"
      "Digest realm=a, Realm=b" None;
    challenges "9110 §11.2" "and so is one a challenge names twice"
      "Digest realm=a, realm=b, Basic realm=c" None;
    credentials "9110 §11.1" "a scheme is compared without case" "BeArEr abc"
      (Some "bearer abc");
    credentials "9110 §11.4" "one or more spaces follow the scheme"
      "Bearer   abc" (Some "bearer abc");
    credentials "9110 §11.2" "a token68 may end in padding"
      "Basic dXNlcjpwYXNz==" (Some "basic dXNlcjpwYXNz==");
    credentials "9110 §11.2" "parameters, a value quoted or not"
      {|Digest username="Mufasa", nc=00000001|}
      (Some "digest {username=[Mufasa]; nc=[00000001]}");
    credentials "9110 §11.2" "a parameter's = may have whitespace around it"
      {|Digest realm = "x"|} (Some "digest {realm=[x]}");
    credentials "9110 §11.4" "a scheme may stand alone" "Negotiate"
      (Some "negotiate {}");
    credentials "9110 §11.4" "two tokens are not credentials" "Bearer a b" None;
    challenges "9110 §11.6.1" "a comma inside a quoted parameter starts nothing"
      {|Newauth realm="apps", type=1, title="Login to \"apps\"", Basic realm="simple"|}
      (Some
         {|newauth {realm=[apps]; type=[1]; title=[Login to "apps"]} | basic {realm=[simple]}|});
    challenges "9110 §11.6.1" "a token68 challenge, then another"
      "Basic abc==, Bearer realm=x" (Some "basic abc== | bearer {realm=[x]}");
    challenges "9110 §11.6.1" "a parameter before any scheme is refused"
      {|realm="x"|} None;
  ]

(* Credentials a client writes, a server reads back as themselves. *)
let test_printed_credentials_read_back () =
  List.iter
    (fun (a : Auth.t) ->
      Alcotest.(check (option string))
        (show_auth a)
        (Some (show_auth a))
        (Result.to_option
           (Result.map show_auth
              (Result.bind (Auth.to_string a) Auth.credentials))))
    [
      { Auth.scheme = "bearer"; value = Token68 "abc.DEF-_~+/==" };
      {
        Auth.scheme = "digest";
        value = Params [ ("realm", {|a, b "c"|}); ("nc", "1") ];
      };
      { Auth.scheme = "negotiate"; value = Params [] };
    ]

module Accept = Spindle_http.Accept

let show_ranges rs =
  String.concat ", "
    (List.map
       (fun (r : Accept.range) ->
         show_media
           {
             Media_type.type_ = r.type_;
             subtype = r.subtype;
             parameters = r.parameters;
           }
         ^ " " ^ string_of_int r.weight)
       rs)

let show_weighted ts =
  String.concat ", " (List.map (fun (t, w) -> t ^ " " ^ string_of_int w) ts)

let ranges rfc says value owes =
  Value
    { rfc; says; parse = Accept.parse_media; show = show_ranges; value; owes }

let weighted rfc says value owes =
  Value
    {
      rfc;
      says;
      parse = Accept.parse_weighted;
      show = show_weighted;
      value;
      owes;
    }

let offer s =
  match Media_type.parse s with
  | Ok m -> m
  | Error e -> Alcotest.failf "%s: %s" s e

(* What a choice between offers comes to, given the field's value. *)
let chosen rfc says ~choose ~parse ~offers value owes =
  Value
    {
      rfc;
      says;
      parse = (fun v -> Result.map (fun rs -> choose rs offers) (parse v));
      show = Option.value ~default:"nothing";
      value;
      owes = Some owes;
    }

let choose_media rs offers =
  Option.map show_media (Accept.choose_media rs (List.map offer offers))

let negotiation_values =
  [
    ranges "9110 §12.4.2" "a range with no q weighs 1, and q=0.5 half of it"
      "text/html;q=0.5, application/json"
      (Some "text/html 500, application/json 1000");
    ranges "9110 §12.4.2" "the q is compared without case" "text/html;Q=0.25"
      (Some "text/html 250");
    ranges "9110 §12.4.2" "a quality value has at most three decimals"
      "text/html;q=0.1234" None;
    ranges "9110 §12.4.2" "no quality value is above 1" "text/html;q=1.5" None;
    ranges "9110 §12.4.2" "1 may be written with zeros after it"
      "text/html;q=1.000" (Some "text/html 1000");
    ranges "9110 §12.4.2" "and with nothing else after it" "text/html;q=1.001"
      None;
    ranges "9110 §12.5.1" "a range's parameters come before its weight"
      "text/html;level=1;q=0.2" (Some "text/html;level=[1] 200");
    ranges "9110 §12.5.1" "nothing comes after a weight"
      "text/html;q=0.2;level=1" None;
    ranges "9110 §12.5.1" "the wildcards" "*/*;q=0.1, text/*"
      (Some "*/* 100, text/* 1000");
    weighted "9110 §12.5.4" "a language, weighted, compared without case"
      "da, en-GB;q=0.8, EN;q=0.7" (Some "da 1000, en-gb 800, en 700");
    weighted "9110 §12.5.3" "a token list takes no other parameter"
      "gzip;level=1" None;
    chosen "9110 §12.5.1" "the most specific range decides an offer's weight"
      ~choose:choose_media ~parse:Accept.parse_media
      ~offers:[ "text/html"; "text/plain"; "image/png" ]
      "text/*;q=0.3, text/plain;q=0.7, */*;q=0.1" "text/plain";
    chosen "9110 §12.5.1" "a weight of 0 is not accepted" ~choose:choose_media
      ~parse:Accept.parse_media
      ~offers:[ "text/csv"; "application/json" ]
      "text/csv;q=0, */*" "application/json";
    chosen "9110 §12.5.1" "a tie goes to the route's own order"
      ~choose:choose_media ~parse:Accept.parse_media
      ~offers:[ "text/csv"; "application/json" ]
      "*/*" "text/csv";
    chosen "9110 §12.5.1" "what nothing accepts is not chosen"
      ~choose:choose_media ~parse:Accept.parse_media ~offers:[ "image/png" ]
      "text/*" "nothing";
    chosen "9110 §12.5.4" "a range matches the tags it begins"
      ~choose:Accept.choose_language ~parse:Accept.parse_weighted
      ~offers:[ "fr"; "en-US"; "en-GB" ] "en-GB;q=0.8, en;q=0.5, *;q=0.1"
      "en-GB";
    chosen "9110 §12.5.4" "en matches en-US, and not eng"
      ~choose:Accept.choose_language ~parse:Accept.parse_weighted
      ~offers:[ "eng"; "en-US" ] "en" "en-US";
    chosen "9110 §12.5.3" "identity is acceptable unless excluded"
      ~choose:Accept.choose_encoding ~parse:Accept.parse_weighted
      ~offers:[ "identity"; "gzip" ] "gzip;q=0" "identity";
    chosen "9110 §12.5.3" "an empty list accepts identity alone"
      ~choose:Accept.choose_encoding ~parse:Accept.parse_weighted
      ~offers:[ "gzip"; "identity" ] "" "identity";
    chosen "9110 §12.5.3" "* at 0 excludes identity too"
      ~choose:Accept.choose_encoding ~parse:Accept.parse_weighted
      ~offers:[ "identity" ] "*;q=0" "nothing";
    chosen "9110 §12.5.2" "* weighs what is not named"
      ~choose:Accept.choose_token ~parse:Accept.parse_weighted
      ~offers:[ "utf-8"; "iso-8859-5" ] "iso-8859-5, *;q=0.5" "iso-8859-5";
  ]

module Cache_control = Spindle_http.Cache_control

let show_directives d =
  String.concat ", "
    (List.map (function n, None -> n | n, Some v -> n ^ "=[" ^ v ^ "]") d)

let directives rfc says value owes =
  Value
    {
      rfc;
      says;
      parse = Cache_control.parse;
      show = show_directives;
      value;
      owes;
    }

let seconds rfc says value owes =
  Value
    {
      rfc;
      says;
      parse =
        (fun v ->
          Result.map
            (fun d -> Cache_control.delta_seconds d "max-age")
            (Cache_control.parse v));
      show = (function Some n -> string_of_int n | None -> "none");
      value;
      owes = Some owes;
    }

let cache_control_values =
  [
    directives "9111 §5.2" "a directive's name is compared without case"
      "Max-Age=60, No-Store" (Some "max-age=[60], no-store");
    directives "9111 §5.2" "an argument may be a quoted string, holding a comma"
      {|private="Set-Cookie, Authorization"|}
      (Some "private=[Set-Cookie, Authorization]");
    directives "9111 §5.2" "no whitespace stands around the equals sign"
      "max-age = 60" None;
    directives "9110 §5.6.1" "empty directives are passed over"
      "no-cache, , private" (Some "no-cache, private");
    seconds "9111 §1.2.2" "delta-seconds are digits" "max-age=60" "60";
    seconds "9111 §5.2" "a recipient accepts them quoted" {|max-age="60"|} "60";
    seconds "9111 §1.2.2" "too large is 2^31" "max-age=99999999999999999999"
      "2147483648";
    seconds "9111 §1.2.2" "a sign is not a digit" "max-age=-1" "none";
    seconds "9111 §5.2" "of two, the first counts" "max-age=5, max-age=10" "5";
  ]

(* What a server writes, it reads back as itself: an argument that is no
   token is quoted. *)
let test_a_printed_cache_control_reads_back () =
  let d =
    [
      ("no-cache", Some "Set-Cookie, Vary");
      ("max-age", Some "0");
      ("private", None);
    ]
  in
  Alcotest.(check (option string))
    "read back"
    (Some (show_directives d))
    (Result.to_option
       (Result.map show_directives
          (Result.bind (Cache_control.to_string d) Cache_control.parse)))

module Date = Spindle_http.Date
module Etag = Spindle_http.Etag
module Range = Spindle_http.Range

(* 2026-09-30, for the two-digit year. *)
let now = 1_790_000_000_000

let dates rfc says value owes =
  Value
    {
      rfc;
      says;
      parse = (fun v -> Option.to_result ~none:"no date" (Date.parse ~now v));
      show = string_of_int;
      value;
      owes;
    }

let show_tag (t : Etag.t) =
  (if t.weak then "weak " else "") ^ "[" ^ t.opaque ^ "]"

let tags rfc says value owes =
  Value
    {
      rfc;
      says;
      parse = Etag.condition;
      show =
        (function
        | Etag.Any -> "any"
        | Etag.Tags ts -> String.concat ", " (List.map show_tag ts));
      value;
      owes;
    }

let show_range = function
  | Range.Other unit -> "other " ^ unit
  | Range.Bytes specs ->
      String.concat ", "
        (List.map
           (function
             | Range.From a -> Printf.sprintf "%d-" a
             | Range.Span (a, b) -> Printf.sprintf "%d-%d" a b
             | Range.Suffix n -> Printf.sprintf "-%d" n)
           specs)

let ranges rfc says value owes =
  Value { rfc; says; parse = Range.parse; show = show_range; value; owes }

let representation_values =
  [
    dates "9110 §5.6.7" "an IMF-fixdate" "Sun, 06 Nov 1994 08:49:37 GMT"
      (Some "784111777000");
    dates "9110 §5.6.7" "the obsolete RFC 850 form"
      "Sunday, 06-Nov-94 08:49:37 GMT" (Some "784111777000");
    dates "9110 §5.6.7" "the obsolete asctime form" "Sun Nov  6 08:49:37 1994"
      (Some "784111777000");
    dates "9110 §5.6.7"
      "a two-digit year more than fifty years ahead is the century before"
      "Friday, 01-Jan-99 00:00:00 GMT" (Some "915148800000");
    dates "9110 §5.6.7" "and one within fifty years is this century"
      "Tuesday, 01-Jan-30 00:00:00 GMT" (Some "1893456000000");
    dates "9110 §5.6.7"
      "a date a second more than fifty years ahead is the century before"
      "Tuesday, 21-Sep-76 14:13:21 GMT" (Some "212163201000");
    dates "9110 §5.6.7" "and one exactly fifty years ahead is not"
      "Monday, 21-Sep-76 14:13:20 GMT" (Some "3367923200000");
    dates "9110 §5.6.7" "a date is case-sensitive"
      "sun, 06 nov 1994 08:49:37 gmt" None;
    dates "9110 §5.6.7" "a day that does not exist is no date"
      "Thu, 30 Feb 2023 00:00:00 GMT" None;
    dates "9110 §5.6.7" "the zone is GMT" "Sun, 06 Nov 1994 08:49:37 UTC" None;
    dates "9110 §5.6.7" "a leap second is a second"
      "Wed, 31 Dec 2008 23:59:60 GMT" (Some "1230768000000");
    tags "9110 §8.8.3" "a list of tags, one weak" {|"a", W/"b"|}
      (Some "[a], weak [b]");
    tags "9110 §8.8.3" "an opaque tag may hold a comma" {|"a,b", "c"|}
      (Some "[a,b], [c]");
    tags "9110 §8.8.3" "W/ is case-sensitive" {|w/"a"|} None;
    tags "9110 §13.1.2" "a star is any" "*" (Some "any");
    tags "9110 §8.8.3" "a tag is quoted" "abc" None;
    ranges "9110 §14.1.1" "an int-range, a suffix and an open range"
      "bytes=0-499, -500, 9500-" (Some "0-499, -500, 9500-");
    ranges "9110 §14.1" "a unit is compared without case" "Bytes=1-2"
      (Some "1-2");
    ranges "9110 §14.1.1" "a range that ends before it starts is invalid"
      "bytes=5-2" None;
    ranges "9110 §14.1.1" "a range-set is not empty" "bytes=" None;
    ranges "9110 §14.1" "another unit is kept, unread" "pages=1-2"
      (Some "other pages");
    ranges "9110 §14.1.1" "a position past what holds is past every end"
      "bytes=99999999999999999999999-"
      (Some (Printf.sprintf "%d-" max_int));
  ]

(* A representation's answers, from a file on disk: each row a request's
   fields and the status RFC 9110 has it answered with. *)
let representation_row rfc says headers status = (rfc, says, headers, status)

let representation_rows =
  let tag = "TAG" and date = "DATE" in
  [
    representation_row "9110 §13.2.2" "If-Match is evaluated first"
      [ ("if-match", {|"other"|}); ("if-none-match", tag) ]
      412;
    representation_row "9110 §13.1.1" "If-Match compares strongly"
      [ ("if-match", "W/" ^ tag) ]
      412;
    representation_row "9110 §13.1.4"
      "If-Unmodified-Since, only without If-Match"
      [
        ("if-match", tag);
        ("if-unmodified-since", "Thu, 01 Jan 1970 00:00:00 GMT");
      ]
      200;
    representation_row "9110 §13.1.2" "If-None-Match compares weakly"
      [ ("if-none-match", "W/" ^ tag) ]
      304;
    representation_row "9110 §13.1.3"
      "If-Modified-Since, only without If-None-Match"
      [ ("if-none-match", {|"other"|}); ("if-modified-since", date) ]
      200;
    representation_row "9110 §13.1.3" "a date later than now is no date"
      [ ("if-modified-since", "Fri, 01 Jan 2100 00:00:00 GMT") ]
      200;
    representation_row "9110 §13.1.5" "If-Range compares strongly"
      [ ("range", "bytes=0-1"); ("if-range", "W/" ^ tag) ]
      200;
    representation_row "9110 §13.1.5" "If-Range by exactly the date"
      [ ("range", "bytes=0-1"); ("if-range", date) ]
      206;
    representation_row "9110 §14.2" "a range past the end is 416"
      [ ("range", "bytes=100-") ]
      416;
    representation_row "9110 §14.2" "a range of another unit is ignored"
      [ ("range", "lines=1-2") ]
      200;
    representation_row "9110 §14.2" "an invalid range is ignored"
      [ ("range", "bytes=x-y") ]
      200;
  ]

let test_a_representation_answers_as_the_rfc_says () =
  Eio_main.run @@ fun env ->
  let dir = Filename.temp_dir "spindle_rfc" "" in
  let root = Eio.Path.(Eio.Stdenv.fs env / dir) in
  Eio.Path.save ~create:(`Or_truncate 0o644)
    Eio.Path.(root / "f.txt")
    "0123456789";
  let app = Spindle.Test.app [ Spindle.Files.route root ] in
  let call headers =
    Spindle.Test.call ~now:3_000_000_000_000 ~headers app `GET "/f.txt"
  in
  let whole = call [] in
  let field name = Option.value ~default:"" (Spindle.Test.header whole name) in
  let fill v =
    if String.equal v "TAG" then field "etag"
    else if String.equal v "W/TAG" then "W/" ^ field "etag"
    else if String.equal v "DATE" then field "last-modified"
    else v
  in
  List.iter
    (fun (rfc, says, headers, status) ->
      Alcotest.(check int)
        (rfc ^ ": " ^ says)
        status (call (List.map (fun (n, v) -> (n, fill v)) headers)).status)
    representation_rows

module Forwarded = Spindle_http.Forwarded

let show_node (n : Forwarded.node) =
  (match n.name with
    | Forwarded.Address a -> a
    | Unknown -> "unknown"
    | Obfuscated o -> o)
  ^
  match n.port with
  | None -> ""
  | Some (Port p) -> ":" ^ string_of_int p
  | Some (Obfuscated_port o) -> ":" ^ o

let show_element (e : Forwarded.element) =
  String.concat ";"
    (List.filter_map Fun.id
       [
         Option.map (fun n -> "for=" ^ show_node n) e.for_;
         Option.map (fun n -> "by=" ^ show_node n) e.by;
         Option.map (fun h -> "host=" ^ h) e.host;
         Option.map (fun p -> "proto=" ^ p) e.proto;
       ]
    @ List.map (fun (n, v) -> n ^ "=" ^ v) e.extensions)

let forwarded rfc says value owes =
  Value
    {
      rfc;
      says;
      parse = Forwarded.parse;
      show = (fun es -> String.concat " | " (List.map show_element es));
      value;
      owes;
    }

let forwarded_values =
  [
    forwarded "7239 §4" "an element's parameters, one proxy's"
      "for=192.0.2.60;proto=http;by=203.0.113.43"
      (Some "for=192.0.2.60;by=203.0.113.43;proto=http");
    forwarded "7239 §4" "a parameter's name is compared without case"
      "For=192.0.2.43" (Some "for=192.0.2.43");
    forwarded "7239 §4" "each proxy an element, the nearest last"
      "for=192.0.2.43, for=198.51.100.17"
      (Some "for=192.0.2.43 | for=198.51.100.17");
    forwarded "7239 §6" "an IPv6 node is bracketed and quoted, with its port"
      {|for="[2001:db8:cafe::17]:4711"|} (Some "for=2001:db8:cafe::17:4711");
    forwarded "7239 §6" "unquoted, an IPv6 node is no token" "for=[2001:db8::1]"
      None;
    forwarded "7239 §6.2" "a node may be unknown" "for=unknown"
      (Some "for=unknown");
    forwarded "7239 §6.3" "or hidden, its port too"
      {|for=_hidden, for="_SEVKISEK:_port1"|}
      (Some "for=_hidden | for=_SEVKISEK:_port1");
    forwarded "7239 §6" "a port has five digits at most, and fits"
      {|for="192.0.2.43:70000"|} None;
    forwarded "7239 §6" "a name is no node" "for=example.com" None;
    forwarded "7239 §5.4" "proto is a scheme" "proto=1http" None;
    forwarded "7239 §4" "a parameter is given once per element"
      "for=192.0.2.43;for=198.51.100.17" None;
    forwarded "7239 §4" "an element holds no whitespace"
      "for=192.0.2.43; proto=https" None;
    forwarded "7239 §5.5" "another parameter is kept" "for=192.0.2.43;secret=x"
      (Some "for=192.0.2.43;secret=x");
  ]

(* Host and scheme come from the header a trusted proxy writes, and only
   that one: the other is whatever the client sent. *)
let test_a_proxy_is_read_in_its_own_header () =
  let host proxy_header headers =
    (Spindle.Test.call ~proxied:true ~proxy_header ~headers app `GET "/host")
      .body
  in
  let both =
    [
      ("host", "t");
      ("x-forwarded-host", "xff.example");
      ("forwarded", "for=192.0.2.43;host=Fwd.example");
    ]
  in
  Alcotest.(check string)
    "Forwarded, its host" "fwd.example"
    (host Spindle.Request.Forwarded both);
  Alcotest.(check string)
    "X-Forwarded-For, its host" "xff.example"
    (host Spindle.Request.X_forwarded_for both);
  Alcotest.(check string)
    "of two elements, the nearest proxy's" "near.example"
    (host Spindle.Request.Forwarded
       [ ("host", "t"); ("forwarded", "host=far.example, host=near.example") ]);
  Alcotest.(check string)
    "a Forwarded that does not parse says nothing" "t"
    (host Spindle.Request.Forwarded [ ("host", "t"); ("forwarded", "host") ])

(* ------------------------------------------------------------------ *)
(* Printers and parsers

   What a printer writes, its parser reads back as itself, and what it would
   not, the printer refuses. Each generator draws from an alphabet of the
   characters that matter at a grammar's edges -- case, a space, a quote, a
   separator, a control character, obs-text -- and repeats names, so a
   printer that writes what its parser refuses or reads otherwise is found.
   Canonical values beside them must be written, so a printer that refuses
   everything does not pass. *)

let gen_edgy alphabet = G.(string_size ~gen:(oneof_list alphabet) (0 -- 4))
let name_chars = [ 'a'; 'b'; 'B'; '-'; ' '; '"'; ';'; '='; ','; '\x01' ]

let value_chars =
  [ 'a'; 'Z'; '0'; ' '; '"'; '\\'; ';'; ','; '\t'; '\x00'; '\x7f'; '\xe9' ]

let gen_name = gen_edgy name_chars
let gen_value = gen_edgy value_chars
let gen_pairs = G.(list_size (0 -- 3) (pair gen_name gen_value))

(* Canonical: lower-case tokens, distinct names, values a quoted string
   holds. *)
let gen_canonical_name =
  G.(string_size ~gen:(oneof_list [ 'a'; 'b'; 'c' ]) (1 -- 3))

let gen_canonical_value =
  gen_edgy [ 'a'; 'Z'; ' '; '"'; '\\'; ';'; ','; '\xe9' ]

let distinct pairs =
  List.rev
    (List.fold_left
       (fun kept (n, v) ->
         if List.mem_assoc n kept then kept else (n, v) :: kept)
       [] pairs)

let gen_canonical_pairs =
  G.(
    map distinct
      (list_size (0 -- 3) (pair gen_canonical_name gen_canonical_value)))

let reads_back ~name ~show ~write ~read gen =
  QCheck.Test.make ~count:2000 ~name (QCheck.make ~print:show gen) (fun v ->
      match write v with
      | Error _ -> true
      | Ok s -> (
          match read s with
          | Ok r when String.equal (show r) (show v) -> true
          | Ok r -> QCheck.Test.fail_reportf "%S read back as %s" s (show r)
          | Error _ -> QCheck.Test.fail_reportf "%S is refused" s))

let is_written ~name ~show ~write gen =
  QCheck.Test.make ~count:500 ~name (QCheck.make ~print:show gen) (fun v ->
      Result.is_ok (write v))

let gen_media pairs name =
  G.(
    map3
      (fun type_ subtype parameters ->
        { Media_type.type_; subtype; parameters })
      name name pairs)

let gen_auth pairs name token =
  G.(
    map2
      (fun scheme value -> { Auth.scheme; value })
      name
      (oneof
         [
           map (fun t -> Auth.Token68 t) token;
           map (fun ps -> Auth.Params ps) pairs;
         ]))

let gen_token68 = gen_edgy [ 'a'; 'Z'; '9'; '/'; '='; ' '; '"' ]

let gen_canonical_token68 =
  G.(string_size ~gen:(oneof_list [ 'a'; 'Z'; '9'; '/'; '~' ]) (1 -- 4))

let gen_directives pairs =
  G.map
    (List.map (fun (n, v) -> (n, if String.equal v "" then None else Some v)))
    pairs

let gen_node =
  G.(
    map2
      (fun name port -> { Forwarded.name; port })
      (oneof
         [
           oneof_list
             [
               Forwarded.Address "192.0.2.1";
               Address "2001:db8::1";
               Address "300.1.1.1";
               Unknown;
             ];
           map
             (fun o -> Forwarded.Obfuscated ("_" ^ o))
             (gen_edgy [ 'a'; '.'; ' ' ]);
         ])
      (option
         (oneof
            [
              map (fun p -> Forwarded.Port p) (0 -- 70000);
              map
                (fun o -> Forwarded.Obfuscated_port ("_" ^ o))
                (gen_edgy [ 'a'; ' ' ]);
            ])))

let gen_element =
  G.(
    map3
      (fun (for_, by) (host, proto) extensions ->
        { Forwarded.for_; by; host; proto; extensions })
      (pair (option gen_node) (option gen_node))
      (pair (option gen_value)
         (option (oneof_list [ "https"; "HTTP"; "1x"; "" ])))
      (list_size (0 -- 2)
         (pair
            (oneof [ gen_name; oneof_list [ "for"; "host"; "x" ] ])
            gen_value)))

let show_elements es = String.concat " | " (List.map show_element es)

let gen_etag =
  G.(
    map2
      (fun weak opaque -> { Etag.weak; opaque })
      bool
      (gen_edgy [ 'a'; '-'; ' '; '"'; '\x01'; '\xe9' ]))

let show_etag (t : Etag.t) =
  (if t.weak then "W/" else "") ^ "[" ^ t.opaque ^ "]"

module Structured = Spindle_http.Structured

let show_bare = function
  | Structured.Integer n -> "i" ^ string_of_int n
  | Decimal n -> "d" ^ string_of_int n
  | String s -> "s[" ^ String.escaped s ^ "]"
  | Token t -> "t[" ^ String.escaped t ^ "]"
  | Bytes b -> "b[" ^ String.escaped b ^ "]"
  | Boolean b -> if b then "?1" else "?0"
  | Date n -> "@" ^ string_of_int n
  | Display s -> "%[" ^ String.escaped s ^ "]"

let show_sf_parameters ps =
  String.concat "" (List.map (fun (k, v) -> ";" ^ k ^ "=" ^ show_bare v) ps)

let show_item (b, ps) = show_bare b ^ show_sf_parameters ps

let show_dictionary d =
  String.concat ", "
    (List.map
       (fun (k, m) ->
         k ^ "="
         ^
         match m with
         | Structured.Item i -> show_item i
         | Inner (is, ps) ->
             "("
             ^ String.concat " " (List.map show_item is)
             ^ ")" ^ show_sf_parameters ps)
       d)

let gen_bare =
  let edges = [ 999_999_999_999_999; -999_999_999_999_999; min_int; max_int ] in
  G.(
    oneof
      [
        map (fun n -> Structured.Integer n) (oneof [ int; oneof_list edges ]);
        map (fun n -> Structured.Decimal n) (oneof [ int; oneof_list edges ]);
        map (fun s -> Structured.String s) gen_value;
        map
          (fun s -> Structured.Token s)
          (gen_edgy [ 'a'; 'Z'; '*'; ':'; '/'; ' ' ]);
        map (fun s -> Structured.Bytes s) gen_value;
        map (fun b -> Structured.Boolean b) bool;
        map (fun n -> Structured.Date n) (oneof [ int; 0 -- 2_000_000_000 ]);
        map (fun s -> Structured.Display s) gen_value;
      ])

let gen_key = gen_edgy [ 'a'; 'b'; 'A'; '*'; '-'; ' ' ]
let gen_sf_parameters = G.(list_size (0 -- 2) (pair gen_key gen_bare))
let gen_item = G.pair gen_bare gen_sf_parameters

let gen_dictionary =
  G.(
    list_size (0 -- 3)
      (pair gen_key
         (oneof
            [
              map (fun i -> Structured.Item i) gen_item;
              map2
                (fun is ps -> Structured.Inner (is, ps))
                (list_size (0 -- 2) gen_item)
                gen_sf_parameters;
            ])))

(* The first and the last instant four digits of a year hold. *)
let earliest_date_ms = -62_167_219_200_000
let latest_date_ms = 253_402_300_799_999

(* An instant reads back as its second, and one past what four digits of a
   year hold as the nearest that is not. *)
let test_a_written_date_reads_back_as_its_second =
  QCheck.Test.make ~count:2000 ~name:"a written date reads back as its second"
    (QCheck.make ~print:string_of_int
       G.(
         oneof
           [
             int;
             earliest_date_ms -- latest_date_ms;
             oneof_list
               [
                 earliest_date_ms - 1; latest_date_ms + 1; min_int; max_int; -1;
               ];
           ]))
    (fun ms ->
      let clamped = Int.min latest_date_ms (Int.max earliest_date_ms ms) in
      let second =
        (if clamped < 0 && clamped mod 1000 <> 0 then (clamped / 1000) - 1
         else clamped / 1000)
        * 1000
      in
      let written = Write.date ms in
      match Date.parse ~now written with
      | Some read when read = second -> true
      | Some read ->
          QCheck.Test.fail_reportf "%S read back as %d, not %d" written read
            second
      | None -> QCheck.Test.fail_reportf "%S is refused" written)

let printers_and_parsers =
  [
    reads_back ~name:"a media type" ~show:show_media ~write:Media_type.to_string
      ~read:Media_type.parse
      (gen_media gen_pairs gen_name);
    is_written ~name:"a canonical media type" ~show:show_media
      ~write:Media_type.to_string
      (gen_media gen_canonical_pairs gen_canonical_name);
    reads_back ~name:"credentials" ~show:show_auth ~write:Auth.to_string
      ~read:Auth.credentials
      (gen_auth gen_pairs gen_name gen_token68);
    reads_back ~name:"a challenge" ~show:show_auth ~write:Auth.to_string
      ~read:(fun s ->
        match Auth.challenges s with
        | Ok [ c ] -> Ok c
        | Ok _ -> Error "not one challenge"
        | Error e -> Error e)
      (gen_auth gen_pairs gen_name gen_token68);
    is_written ~name:"canonical credentials" ~show:show_auth
      ~write:Auth.to_string
      (gen_auth gen_canonical_pairs gen_canonical_name gen_canonical_token68);
    reads_back ~name:"Cache-Control" ~show:show_directives
      ~write:Cache_control.to_string ~read:Cache_control.parse
      (gen_directives gen_pairs);
    is_written ~name:"canonical Cache-Control" ~show:show_directives
      ~write:Cache_control.to_string
      (gen_directives gen_canonical_pairs);
    reads_back ~name:"Forwarded" ~show:show_elements ~write:Forwarded.to_string
      ~read:Forwarded.parse
      G.(list_size (0 -- 2) gen_element);
    is_written ~name:"a canonical Forwarded" ~show:show_elements
      ~write:Forwarded.to_string
      G.(
        map2
          (fun host extensions ->
            [
              {
                Forwarded.for_ =
                  Some { name = Address "192.0.2.1"; port = Some (Port 8080) };
                by = None;
                host = Some host;
                proto = Some "https";
                extensions;
              };
            ])
          gen_canonical_value
          (map
             (List.filter (fun (n, _) ->
                  not (List.mem n [ "for"; "by"; "host"; "proto" ])))
             gen_canonical_pairs));
    reads_back ~name:"an entity tag" ~show:show_etag ~write:Etag.to_string
      ~read:Etag.parse gen_etag;
    reads_back ~name:"a structured item" ~show:show_item
      ~write:Structured.item_to_string ~read:Structured.item gen_item;
    reads_back ~name:"a structured dictionary" ~show:show_dictionary
      ~write:Structured.dictionary_to_string ~read:Structured.dictionary
      gen_dictionary;
    test_a_written_date_reads_back_as_its_second;
  ]

let () =
  let named rows f = List.map f rows in
  Alcotest.run "http_rfc"
    [
      ("heads", named heads reading_case);
      ("bodies", named bodies reading_case);
      ("the server", named server server_case);
      ("what the server writes", named writing server_case);
      ("the attack corpus", named attacks server_case);
      ("responses", named responses response_case);
      ( "the client",
        named client_rows client_case
        @ [
            Alcotest.test_case
              "9112 §9.2: bytes on a kept connection are not the next answer"
              `Quick test_bytes_on_a_kept_connection_are_not_the_next_answer;
            Alcotest.test_case
              "9112 §9.5: a kept connection the server closed is not lent"
              `Quick test_a_kept_connection_the_server_closed_is_not_lent;
            Alcotest.test_case
              "9112 §9.2: bytes after a TLS answer are not the next answer"
              `Quick test_bytes_after_a_tls_answer_are_not_the_next_answer;
          ] );
      ( "field values",
        named
          (field_values @ auth_values @ negotiation_values
         @ cache_control_values @ forwarded_values @ representation_values)
          value_case );
      ( "field values, both ways",
        [
          Alcotest.test_case "9110 §5.6.4: a printed media type reads back"
            `Quick test_a_printed_media_type_reads_back;
          Alcotest.test_case "9110 §8.3.1: a malformed media type is 415" `Quick
            test_a_malformed_media_type_is_refused;
          Alcotest.test_case "9110 §11.4: printed credentials read back" `Quick
            test_printed_credentials_read_back;
          Alcotest.test_case "9111 §5.2: a printed Cache-Control reads back"
            `Quick test_a_printed_cache_control_reads_back;
        ] );
      ( "the writer",
        [
          Alcotest.test_case "9112 §4: the space after the code, with no reason"
            `Quick test_the_space_after_the_code_is_written_with_no_reason;
          Alcotest.test_case
            "9110 §5.5: a value that could split is never written" `Quick
            test_a_value_that_could_split_is_never_written;
          Alcotest.test_case
            "9110 §15: a status the reader refuses is never written" `Quick
            test_a_status_the_reader_refuses_is_never_written;
          Alcotest.test_case
            "9112 §3: a target that could split is never written" `Quick
            test_a_target_that_could_split_is_never_written;
        ] );
      ( "the framework",
        [
          Alcotest.test_case "9110 §5.6.7: a date is an IMF-fixdate" `Quick
            test_a_date_is_an_imf_fixdate;
          Alcotest.test_case "9110 §13, §14: a representation's answers" `Quick
            test_a_representation_answers_as_the_rfc_says;
          Alcotest.test_case
            "9110 §15.5.2: a 401 without a challenge is refused" `Quick
            test_a_401_without_a_challenge_is_refused;
          Alcotest.test_case "9110 §9.1: 501 comes before the not-found answer"
            `Quick test_501_comes_before_the_not_found_answer;
          Alcotest.test_case "9112 §3.2.2: a trusted proxy's host comes first"
            `Quick test_a_proxy's_host_comes_first;
          Alcotest.test_case "7239 §5.3: a proxy is read in its own header"
            `Quick test_a_proxy_is_read_in_its_own_header;
          Alcotest.test_case "9112 §6.1: an HTTP/1.0 stream, in-process" `Quick
            test_an_http_1_0_stream_in_process;
          Alcotest.test_case "a connection failing under a head is a value"
            `Quick test_a_connection_failing_under_a_head_is_a_value;
        ] );
      ( "printers and parsers",
        List.map QCheck_alcotest.to_alcotest printers_and_parsers );
      ( "properties",
        [
          QCheck_alcotest.to_alcotest test_writing_then_reading_is_the_identity;
          QCheck_alcotest.to_alcotest test_read_boundaries_change_nothing;
          QCheck_alcotest.to_alcotest
            test_writing_then_reading_a_response_is_the_identity;
          QCheck_alcotest.to_alcotest test_what_the_writer_accepts_is_read;
          QCheck_alcotest.to_alcotest
            test_response_read_boundaries_change_nothing;
          Alcotest.test_case "every row holds at any cut" `Quick
            test_every_row_holds_at_any_cut;
          QCheck_alcotest.to_alcotest
            test_no_input_crashes_hangs_or_reads_past_a_limit;
          QCheck_alcotest.to_alcotest
            test_no_response_crashes_hangs_or_reads_past_a_limit;
          Alcotest.test_case "every request is answered once, in order" `Quick
            test_every_request_is_answered_once_in_order;
        ] );
      ( "the referee",
        [
          QCheck_alcotest.to_alcotest
            test_the_referee_agrees_where_nothing_is_listed;
          QCheck_alcotest.to_alcotest
            test_the_referee_agrees_on_responses_where_nothing_is_listed;
        ] );
    ]
