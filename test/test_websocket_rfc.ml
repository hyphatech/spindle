(* The conformance table for RFC 6455: every requirement Spindle meets, as a
   server and as a client, a row each, named by its section. One function
   runs a row: frames through one end of a socket, a handshake through the
   application, or a client's handshake against a server that says what the
   row says. A frame row is read whole, a byte at a time, and at cuts a
   generator chooses, through a reader of sixty-four bytes, so a payload is
   always read in pieces: an end that depends on how its bytes arrived is
   one a socket will break. *)

module Ws = Spindle.Websocket
open Spindle.Syntax

let ( let* ) = Result.bind

(* ------------------------------------------------------------------ *)
(* Delivery *)

(* A flow that hands its reader the pieces a test chose, one read each. *)
module Pieces = struct
  type t = { mutable left : string list }

  let read_methods = []

  let single_read t buf =
    match t.left with
    | [] -> raise End_of_file
    | p :: rest ->
        let n = min (String.length p) (Cstruct.length buf) in
        Cstruct.blit_from_string p 0 buf 0 n;
        t.left <-
          (if n = String.length p then rest
           else String.sub p n (String.length p - n) :: rest);
        n
end

let source pieces =
  Eio.Resource.T
    ( { Pieces.left = List.filter (fun p -> String.length p > 0) pieces },
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

let delivery_name = function
  | Whole -> "whole"
  | Bytewise -> "a byte at a time"
  | At cuts -> "cut at " ^ String.concat "," (List.map string_of_int cuts)

(* ------------------------------------------------------------------ *)
(* Frames, written by hand so a row can write one wrong *)

let a_mask = "\x37\xfa\x21\x3d"

let masked m s =
  String.mapi (fun i c -> Char.chr (Char.code c lxor Char.code m.[i land 3])) s

(* [length] declares a length the payload does not have, as a peer may. *)
let frame ?(fin = true) ?(rsv = 0) ?(mask = Some a_mask) ?length opcode payload
    =
  let b = Buffer.create (String.length payload + 14) in
  Buffer.add_char b
    (Char.chr ((if fin then 0x80 else 0) lor (rsv lsl 4) lor opcode));
  let bit = match mask with Some _ -> 0x80 | None -> 0 in
  let n = Option.value length ~default:(String.length payload) in
  if n < 126 then Buffer.add_char b (Char.chr (bit lor n))
  else if n < 65536 then (
    Buffer.add_char b (Char.chr (bit lor 126));
    Buffer.add_uint16_be b n)
  else (
    Buffer.add_char b (Char.chr (bit lor 127));
    Buffer.add_int64_be b (Int64.of_int n));
  (match mask with
  | Some m ->
      Buffer.add_string b m;
      Buffer.add_string b (masked m payload)
  | None -> Buffer.add_string b payload);
  Buffer.contents b

let close_payload code reason =
  let b = Buffer.create 2 in
  Buffer.add_uint16_be b code;
  Buffer.contents b ^ reason

let text ?fin ?mask s = frame ?fin ?mask 1 s
let binary ?fin ?mask s = frame ?fin ?mask 2 s
let continuation ?fin ?mask s = frame ?fin ?mask 0 s
let ping ?mask s = frame ?mask 9 s
let pong ?mask s = frame ?mask 10 s
let close ?mask ?(reason = "") code = frame ?mask 8 (close_payload code reason)

(* ------------------------------------------------------------------ *)
(* What an end wrote, read back *)

type out =
  | Text of string
  | Binary of string
  | Ping of string
  | Pong of string
  | Close of int option
  | Other of int

let show = function
  | Text s ->
      Printf.sprintf "text %S"
        (if String.length s > 20 then String.sub s 0 20 ^ "..." else s)
  | Binary s -> Printf.sprintf "binary %d bytes" (String.length s)
  | Ping s -> Printf.sprintf "ping %S" s
  | Pong s -> Printf.sprintf "pong %S" s
  | Close (Some c) -> Printf.sprintf "close %d" c
  | Close None -> "close, no code"
  | Other o -> Printf.sprintf "opcode %d" o

(* Every frame in what an end wrote, and whether each was masked; a
   fragmented message is not something either end here writes. *)
let frames_of s =
  let n = String.length s in
  let rec at i =
    if i + 2 > n then []
    else
      let b0 = Char.code s.[i] and b1 = Char.code s.[i + 1] in
      let is_masked = b1 land 0x80 <> 0 in
      let len, off =
        match b1 land 0x7f with
        | 126 -> (String.get_uint16_be s (i + 2), i + 4)
        | 127 -> (Int64.to_int (String.get_int64_be s (i + 2)), i + 10)
        | l -> (l, i + 2)
      in
      let m, off =
        if is_masked then (Some (String.sub s off 4), off + 4) else (None, off)
      in
      let payload = String.sub s off len in
      let payload =
        match m with Some m -> masked m payload | None -> payload
      in
      let out =
        match b0 land 0x0f with
        | 1 -> Text payload
        | 2 -> Binary payload
        | 9 -> Ping payload
        | 10 -> Pong payload
        | 8 when String.length payload >= 2 ->
            Close (Some (String.get_uint16_be payload 0))
        | 8 -> Close None
        | o -> Other o
      in
      (is_masked, out) :: at (off + len)
  in
  at 0

(* One end, over the pieces, on a clock that never moves: how its function
   ended, and every byte it wrote. *)
let over_raw delivery input run =
  Eio_mock.Backend.run @@ fun () ->
  let out = Buffer.create 256 in
  let clock =
    (Eio_mock.Clock.Mono.make () :> Eio.Time.Mono.ty Eio.Resource.t)
  in
  let ended =
    Eio.Buf_write.with_flow (Eio.Flow.buffer_sink out) (fun writer ->
        run
          {
            Spindle.Response.reader =
              Eio.Buf_read.of_flow (source (split delivery input)) ~max_size:64;
            writer;
            clock;
            send_timeout_s = 10.;
            stopping = fst (Eio.Promise.create ());
          })
  in
  (ended, Buffer.contents out)

(* And every frame it wrote. *)
let over delivery input run =
  let ended, written = over_raw delivery input run in
  (ended, frames_of written)

(* ------------------------------------------------------------------ *)
(* A server's frames *)

let texts = Ws.protocol ~client:Ws.text ~server:Ws.text ()
let bytes = Ws.protocol ~client:Ws.binary ~server:Ws.binary ()

let echo ws =
  let rec loop () =
    let* m = Ws.receive ws in
    let* () = Ws.send ws m in
    loop ()
  in
  loop ()

type carries = Texts | Bytes

type row = {
  rfc : string;
  says : string;
  sends : string;
  carries : carries;
  max_message : int option;
  answers : out list;
}

let row ?(carries = Texts) ?max_message rfc says sends answers =
  { rfc; says; sends; carries; max_message; answers }

let bye = close 1000

let server_rows =
  [
    row "5.6" "a text message is read whole and answered"
      (text "hello" ^ bye)
      [ Text "hello"; Close (Some 1000) ];
    row "5.2" "a length in two bytes is read, and written in the fewest"
      (text (String.make 300 'a') ^ bye)
      [ Text (String.make 300 'a'); Close (Some 1000) ];
    row "5.2" "and a length in eight"
      (text (String.make 70_000 'b') ^ bye)
      [ Text (String.make 70_000 'b'); Close (Some 1000) ];
    row "5.4" "a fragmented message is put together"
      (text ~fin:false "hel"
      ^ continuation ~fin:false "l"
      ^ continuation "o" ^ bye)
      [ Text "hello"; Close (Some 1000) ];
    row "5.4"
      "a control frame between fragments is answered, and the message still \
       arrives whole"
      (text ~fin:false "he" ^ ping "x" ^ continuation "llo" ^ bye)
      [ Pong "x"; Text "hello"; Close (Some 1000) ];
    row "5.5.2" "a ping is answered with a pong carrying its payload"
      (ping "abc" ^ bye)
      [ Pong "abc"; Close (Some 1000) ];
    row "5.5.3" "a pong nobody asked for is ignored"
      (pong "x" ^ text "a" ^ bye)
      [ Text "a"; Close (Some 1000) ];
    row "5.5.1" "a close is answered with a close naming its code" (close 1001)
      [ Close (Some 1001) ];
    row "5.5.1" "a close naming no code is answered with one naming none"
      (frame 8 "") [ Close None ];
    row "5.6" "a binary message is read as bytes" ~carries:Bytes
      (binary "\x00\xff\x01" ^ bye)
      [ Binary "\x00\xff\x01"; Close (Some 1000) ];
    row "5.1" "a frame from a client that is not masked fails the connection"
      (text ~mask:None "a") [ Close (Some 1002) ];
    row "5.2" "a reserved bit, with no extension agreed, fails it"
      (frame ~rsv:4 1 "a") [ Close (Some 1002) ];
    row "5.2" "an opcode no frame has fails it" (frame 3 "a")
      [ Close (Some 1002) ];
    row "5.5" "a fragmented control frame fails it" (frame ~fin:false 9 "")
      [ Close (Some 1002) ];
    row "5.5" "a control frame longer than 125 bytes fails it"
      (ping (String.make 126 'p'))
      [ Close (Some 1002) ];
    row "5.4" "a continuation of nothing fails it" (continuation "a")
      [ Close (Some 1002) ];
    row "5.4" "a new message before the last one ended fails it"
      (text ~fin:false "a" ^ text "b")
      [ Close (Some 1002) ];
    row "8.1" "a text message that is not UTF-8 fails it with 1007"
      (text "\xff") [ Close (Some 1007) ];
    row "8.1" "a character split across fragments is read whole"
      (text ~fin:false "\xe2\x82" ^ continuation "\xac" ^ bye)
      [ Text "\xe2\x82\xac"; Close (Some 1000) ];
    row "8.1" "and one that is no character across them fails with 1007"
      (text ~fin:false "\xe2\x82" ^ continuation "\x28")
      [ Close (Some 1007) ];
    row "7.4.1" "a close with a code no endpoint may send fails it" (close 1005)
      [ Close (Some 1002) ];
    row "5.5.1" "a close of one byte fails it" (frame 8 "\x03")
      [ Close (Some 1002) ];
    row "5.5.1" "a close reason that is not UTF-8 fails it with 1007"
      (close ~reason:"\xff" 1000)
      [ Close (Some 1007) ];
    row "7.4.1" "a message of a kind the socket does not take is 1003"
      ~carries:Bytes (text "a") [ Close (Some 1003) ];
    row "10.4" "a message longer than the socket takes is 1009" ~max_message:10
      (text (String.make 11 'x'))
      [ Close (Some 1009) ];
    row "10.4" "and so is one that grows past it across fragments"
      ~max_message:10
      (text ~fin:false (String.make 6 'x') ^ continuation (String.make 6 'x'))
      [ Close (Some 1009) ];
    row "10.4"
      "and so is a continuation declaring the longest length a frame may have"
      ~max_message:10
      (text ~fin:false "x" ^ frame ~length:max_int 0 (String.make 64 'x'))
      [ Close (Some 1009) ];
  ]

let serve (r : row) delivery =
  let _, frames =
    over delivery r.sends (fun c ->
        match r.carries with
        | Texts -> Ws.run_server ?max_message:r.max_message texts c echo
        | Bytes -> Ws.run_server ?max_message:r.max_message bytes c echo)
  in
  frames

let check_server (r : row) delivery =
  let frames = serve r delivery in
  let name =
    Printf.sprintf "%s %s (%s)" r.rfc r.says (delivery_name delivery)
  in
  Alcotest.(check (list string))
    name (List.map show r.answers)
    (List.map (fun (_, o) -> show o) frames);
  Alcotest.(check bool)
    (name ^ ": nothing a server writes is masked (5.1)")
    false (List.exists fst frames)

(* The fewest bytes a length allows (5.2): 300 is two, and never eight. *)
let test_a_length_is_written_in_the_fewest_bytes () =
  let written = ref "" in
  Eio_mock.Backend.run (fun () ->
      let out = Buffer.create 512 in
      let clock =
        (Eio_mock.Clock.Mono.make () :> Eio.Time.Mono.ty Eio.Resource.t)
      in
      Eio.Buf_write.with_flow (Eio.Flow.buffer_sink out) (fun writer ->
          ignore
            (Ws.run_server texts
               {
                 Spindle.Response.reader =
                   Eio.Buf_read.of_flow
                     (source [ text (String.make 300 'a') ^ bye ])
                     ~max_size:64;
                 writer;
                 clock;
                 send_timeout_s = 10.;
                 stopping = fst (Eio.Promise.create ());
               }
               echo
              : (unit, Ws.error) result));
      written := Buffer.contents out);
  Alcotest.(check int) "126: a length in two bytes" 126 (Char.code !written.[1])

(* ------------------------------------------------------------------ *)
(* A client's frames *)

type client_row = {
  c_rfc : string;
  c_says : string;
  hears : string;
  does : (string, string) Ws.t -> (string, Ws.error) result;
  gets : (string, string) result;  (** what [does] answers, shown *)
  writes : out list;
}

let shown = function Ok s -> Ok s | Error e -> Error (Ws.error_to_string e)
let receive ws = Ws.receive ws

let client_rows =
  [
    {
      c_rfc = "5.1";
      c_says = "every frame a client writes is masked";
      hears = text ~mask:None "hi" ^ close ~mask:None 1000;
      does =
        (fun ws ->
          let* () = Ws.send ws "there" in
          receive ws);
      gets = Ok "hi";
      writes = [ Text "there"; Close (Some 1000) ];
    };
    {
      c_rfc = "5.1";
      c_says = "a masked frame from a server fails the connection";
      hears = text "a";
      does = receive;
      gets = Error "closed, 1002: a masked frame";
      writes = [ Close (Some 1002) ];
    };
    {
      c_rfc = "5.5.2";
      c_says = "a client answers a ping with a pong";
      hears = ping ~mask:None "p" ^ text ~mask:None "x" ^ close ~mask:None 1000;
      does = receive;
      gets = Ok "x";
      writes = [ Pong "p"; Close (Some 1000) ];
    };
    {
      c_rfc = "5.4";
      c_says = "a fragmented message from a server is put together";
      hears =
        text ~mask:None ~fin:false "ab"
        ^ continuation ~mask:None "c"
        ^ close ~mask:None 1000;
      does = receive;
      gets = Ok "abc";
      writes = [ Close (Some 1000) ];
    };
    {
      c_rfc = "8.1";
      c_says = "a text message from a server that is not UTF-8 is 1007";
      hears = text ~mask:None "\xc3";
      does = receive;
      gets = Error "closed, 1007: a text message that is not UTF-8";
      writes = [ Close (Some 1007) ];
    };
    {
      c_rfc = "5.5.1";
      c_says = "a server's close is answered, and the socket is closed";
      hears = close ~mask:None ~reason:"bye" 1001;
      does = receive;
      gets = Error "closed, 1001: bye";
      writes = [ Close (Some 1001) ];
    };
  ]

let check_client (r : client_row) delivery =
  let got, frames =
    over delivery r.hears (fun c ->
        Ws.run_client ~mask:(fun () -> a_mask) texts c r.does)
  in
  let name =
    Printf.sprintf "%s %s (%s)" r.c_rfc r.c_says (delivery_name delivery)
  in
  Alcotest.(check (result string string)) name r.gets (shown got);
  Alcotest.(check (list string))
    (name ^ ": what it wrote") (List.map show r.writes)
    (List.map (fun (_, o) -> show o) frames);
  Alcotest.(check bool)
    (name ^ ": every frame masked (5.1)")
    true (List.for_all fst frames)

(* §5.5 and §8.1: a close carries 123 bytes of UTF-8 after its code, so a
   reason that is longer, or not UTF-8, is left out rather than sent. *)
let test_a_close_sends_no_reason_it_cannot_carry () =
  List.iter
    (fun (says, reason, sent) ->
      let _, written =
        over_raw Whole (close ~mask:None 1000) (fun c ->
            Ws.run_client
              ~mask:(fun () -> a_mask)
              texts c
              (fun ws ->
                Ws.close ~reason ws;
                receive ws))
      in
      Alcotest.(check string) says (close ~reason:sent 1000) written)
    [
      ("a reason of 123 bytes is sent", String.make 123 'r', String.make 123 'r');
      ("one of 124 is not", String.make 124 'r', "");
      ("nor one that is not UTF-8", "\xff", "");
    ]

(* §5.3: a masking key is four bytes. One of another length is our bug,
   answered as a value rather than raised, and nothing a peer would misread
   is written. *)
let test_a_mask_of_another_length_writes_nothing () =
  List.iter
    (fun key ->
      let got, written =
        over_raw Whole (close ~mask:None 1000) (fun c ->
            Ws.run_client
              ~mask:(fun () -> key)
              texts c
              (fun ws -> Ws.send ws "a"))
      in
      Alcotest.(check (result unit string))
        (Printf.sprintf "a key of %d bytes" (String.length key))
        (Error
           (Printf.sprintf "lost: a mask of %d bytes, where a frame takes 4"
              (String.length key)))
        (shown got);
      Alcotest.(check string) "and nothing written" "" written)
    [ "\x01\x02"; "\x01\x02\x03\x04\x05" ]

(* ------------------------------------------------------------------ *)
(* A server's handshake, through the whole application *)

let named = Ws.protocol ~subprotocol:"chat" ~client:Ws.text ~server:Ws.text ()

let app =
  Spindle.Test.app
    [
      Spindle.get
        Spindle.Path.(s "s")
        (Spindle.Returns.websocket texts)
        (let+ () = Spindle.Dep.return () in
         Ok echo);
      Spindle.get
        Spindle.Path.(s "named")
        (Spindle.Returns.websocket named)
        (let+ () = Spindle.Dep.return () in
         Ok echo);
    ]

(* The key and its accept are RFC 6455's own example (§1.3). *)
let asking =
  [
    ("host", "t");
    ("upgrade", "websocket");
    ("connection", "Upgrade");
    ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==");
    ("sec-websocket-version", "13");
  ]

let without name = List.filter (fun (n, _) -> not (String.equal n name)) asking
let replacing name v = (name, v) :: without name

type handshake_row = {
  h_rfc : string;
  h_says : string;
  path : string;
  version : Spindle_http.Head.version;
  headers : (string * string) list;
  status : int;
  has : (string * string option) list;
      (** a field and its value, or its absence *)
}

let handshake ?(path = "/s") ?(version = Spindle_http.Head.Http_1_1) h_rfc
    h_says headers status has =
  { h_rfc; h_says; path; version; headers; status; has }

let handshake_rows =
  [
    handshake "4.2.2" "a handshake is answered 101, accepting the key" asking
      101
      [
        ("sec-websocket-accept", Some "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
        ("upgrade", Some "websocket");
        ("connection", Some "upgrade");
        ("sec-websocket-protocol", None);
      ];
    handshake "4.2.1"
      "a request that asks for no upgrade is 426, naming websocket"
      (without "upgrade") 426
      [ ("upgrade", Some "websocket") ];
    handshake "4.2.2" "a version other than 13 is 426, naming 13"
      (replacing "sec-websocket-version" "8")
      426
      [ ("sec-websocket-version", Some "13") ];
    handshake "4.2.1" "a key that is not sixteen bytes is 400"
      (replacing "sec-websocket-key" "c2hvcnQ=")
      400 [];
    handshake "4.2.1" "a handshake without Connection: upgrade is 400"
      (replacing "connection" "keep-alive")
      400 [];
    handshake "4.2.1" "an HTTP/1.0 request is 426"
      ~version:Spindle_http.Head.Http_1_0 asking 426 [];
    handshake "4.2.1" "Upgrade and Connection are read whatever their case"
      ( replacing "upgrade" "WebSocket" |> fun h ->
        ("connection", "keep-alive, Upgrade")
        :: List.filter (fun (n, _) -> not (String.equal n "connection")) h )
      101 [];
    handshake "4.2.1"
      "Upgrade and Connection sent on several lines are one list each"
      (("connection", "keep-alive")
      :: ("connection", "Upgrade") :: ("upgrade", "h2c")
      :: ("upgrade", "websocket")
      :: List.filter
           (fun (n, _) ->
             not (String.equal n "connection" || String.equal n "upgrade"))
           asking)
      101 [];
    handshake "4.2.1" ~path:"/named"
      "a protocol offered on a later line is offered all the same"
      (("sec-websocket-protocol", "other")
      :: ("sec-websocket-protocol", "chat")
      :: asking)
      101
      [ ("sec-websocket-protocol", Some "chat") ];
    handshake "4.2.2" ~path:"/named" "a protocol with a name answers with it"
      (("sec-websocket-protocol", "other, chat") :: asking)
      101
      [ ("sec-websocket-protocol", Some "chat") ];
    handshake "4.2.2" ~path:"/named"
      "and refuses a client that did not offer it" asking 400 [];
    handshake "4.2.2"
      "a protocol with no name answers none, whatever was offered"
      (("sec-websocket-protocol", "chat") :: asking)
      101
      [ ("sec-websocket-protocol", None) ];
    handshake "4.2.2" "no extension is agreed, whatever was offered"
      (("sec-websocket-extensions", "permessage-deflate") :: asking)
      101
      [ ("sec-websocket-extensions", None) ];
    handshake "10.2" "a handshake a browser sent from another site is 403"
      (("origin", "https://elsewhere.example")
      :: ("sec-fetch-site", "cross-site")
      :: asking)
      403 [];
  ]

let check_handshake (r : handshake_row) () =
  let a =
    Spindle.Test.call ~version:r.version ~headers:r.headers app `GET r.path
  in
  let name = r.h_rfc ^ " " ^ r.h_says in
  Alcotest.(check int) name r.status a.status;
  List.iter
    (fun (field, value) ->
      Alcotest.(check (option string))
        (name ^ ": " ^ field)
        value
        ( Option.map String.lowercase_ascii (Spindle.Test.header a field)
        |> fun v ->
          match (field, value) with
          | "sec-websocket-accept", _ -> Spindle.Test.header a field
          | _ -> v ))
    r.has

(* ------------------------------------------------------------------ *)
(* A client's handshake, against a server that answers as the row says *)

(* One connection: the head the client sent, then [answer] of its key; and,
   for a 101, every frame after it read and a close answered, so the
   client's own closing handshake completes. *)
let scripted ?(timeout_s = 2.) env answer f =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen net ~sw ~backlog:4 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  let heard = ref [] in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec accept () =
        Eio.Net.accept_fork socket ~sw
          ~on_error:(fun _ -> ())
          (fun flow _ ->
            let r = Eio.Buf_read.of_flow flow ~max_size:65536 in
            let rec head acc =
              match Eio.Buf_read.line r with
              | "" -> List.rev acc
              | l -> head (l :: acc)
            in
            let lines = head [] in
            heard := lines;
            let key =
              List.find_map
                (fun l ->
                  match String.index_opt l ':' with
                  | Some i
                    when String.equal
                           (String.lowercase_ascii (String.sub l 0 i))
                           "sec-websocket-key" ->
                      Some
                        (String.trim
                           (String.sub l (i + 1) (String.length l - i - 1)))
                  | _ -> None)
                lines
              |> Option.value ~default:""
            in
            Eio.Flow.copy_string (answer key) flow;
            (* Answer a close, and read until the client goes. *)
            let rec frames () =
              match Eio.Buf_read.take 2 r with
              | exception End_of_file -> ()
              | h ->
                  let len = Char.code h.[1] land 0x7f in
                  let body = Eio.Buf_read.take (4 + len) r in
                  if Char.code h.[0] land 0x0f = 8 then
                    Eio.Flow.copy_string
                      (close ~mask:None
                         (String.get_uint16_be
                            (masked (String.sub body 0 4)
                               (String.sub body 4 len))
                            0))
                      flow
                  else frames ()
            in
            try frames () with _ -> ());
        accept ()
      in
      accept ());
  let client =
    Spindle_client.create ~sw ~net
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~timeout_s ()
  in
  let url = Printf.sprintf "ws://127.0.0.1:%d/socket" port in
  let got =
    f (fun protocol g -> Spindle_client.websocket client protocol url g)
  in
  (got, !heard)

let upgrade ?(accept = fun key -> Ws.accept_key key) ?(extra = "") key =
  Printf.sprintf
    "HTTP/1.1 101 Switching Protocols\r\n\
     Upgrade: websocket\r\n\
     Connection: Upgrade\r\n\
     Sec-WebSocket-Accept: %s\r\n\
     %s\r\n"
    (accept key) extra

let outcome = function
  | Ok () -> "opened"
  | Error (Spindle_client.Refused r) ->
      Printf.sprintf "refused %d: %s" r.status r.body
  | Error (Spindle_client.Failed e) ->
      "failed: " ^ Spindle_client.error_to_string e
  | Error (Spindle_client.Ended e) -> "ended: " ^ Ws.error_to_string e

let check_client_handshake ?timeout_s env ~protocol answer expected () =
  let got, _ =
    scripted ?timeout_s env answer (fun open_ ->
        open_ protocol (fun _ -> Ok ()))
  in
  let got = outcome got in
  Alcotest.(check bool)
    (Printf.sprintf "%s, where it %s" expected got)
    true
    (String.starts_with ~prefix:expected got)

let test_a_client_asks_as_the_rfc_says env () =
  let got, heard =
    scripted env upgrade (fun open_ -> open_ texts (fun _ -> Ok ()))
  in
  Alcotest.(check string) "opened" "opened" (outcome got);
  let field name =
    List.find_map
      (fun l ->
        match String.index_opt l ':' with
        | Some i
          when String.equal (String.lowercase_ascii (String.sub l 0 i)) name ->
            Some (String.trim (String.sub l (i + 1) (String.length l - i - 1)))
        | _ -> None)
      heard
  in
  Alcotest.(check (option string))
    "4.1: a GET of the resource, in HTTP/1.1" (Some "GET /socket HTTP/1.1")
    (List.nth_opt heard 0);
  Alcotest.(check bool) "4.1: Host" true (Option.is_some (field "host"));
  Alcotest.(check (option string))
    "4.1: Upgrade: websocket" (Some "websocket") (field "upgrade");
  Alcotest.(check (option string))
    "4.1: Connection: Upgrade" (Some "Upgrade") (field "connection");
  Alcotest.(check (option string))
    "4.1: version 13" (Some "13")
    (field "sec-websocket-version");
  Alcotest.(check (option int))
    "4.1: a key of sixteen random bytes" (Some 16)
    (Option.bind (field "sec-websocket-key") (fun k ->
         Result.to_option (Result.map String.length (Base64.decode k))))

let test_a_key_is_fresh_every_time env () =
  let key () =
    let _, heard =
      scripted env upgrade (fun open_ -> open_ texts (fun _ -> Ok ()))
    in
    List.find_opt
      (fun l ->
        String.length l > 17
        && String.equal
             (String.lowercase_ascii (String.sub l 0 17))
             "sec-websocket-key")
      heard
  in
  let a = key () and b = key () in
  Alcotest.(check bool)
    "4.1: two handshakes, two keys" false
    (Option.equal String.equal a b)

let client_handshake_rows env =
  let row rfc says ?(protocol = texts) ?timeout_s answer expected =
    Alcotest.test_case
      (rfc ^ " " ^ says)
      `Quick
      (check_client_handshake ?timeout_s env ~protocol answer expected)
  in
  [
    row "4.1" "a 101 that accepts the key opens the socket" upgrade "opened";
    row "4.1" "an answer that is not a 101 is refused, with its words"
      (fun _ -> "HTTP/1.1 403 Forbidden\r\nContent-Length: 4\r\n\r\nNope")
      "refused 403: Nope";
    row "4.1" "a refusal whose body stalls is held to the handshake's deadline"
      ~timeout_s:0.2
      (fun _ -> "HTTP/1.1 403 Forbidden\r\nContent-Length: 100\r\n\r\nNot all")
      "failed: no answer within";
    row "4.1" "a 101 whose accept is not for this key fails"
      (upgrade ~accept:(fun _ -> "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
      "failed: a 101 whose Sec-WebSocket-Accept";
    row "4.1" "a 101 that does not name websocket fails"
      (fun key ->
        Printf.sprintf
          "HTTP/1.1 101 Switching Protocols\r\n\
           Upgrade: h2c\r\n\
           Connection: Upgrade\r\n\
           Sec-WebSocket-Accept: %s\r\n\
           \r\n"
          (Ws.accept_key key))
      "failed: a 101 that does not name websocket";
    row "4.1" "a 101 speaking a protocol nobody asked for fails"
      (upgrade ~extra:"Sec-WebSocket-Protocol: chat\r\n")
      "failed: a 101 speaking another protocol";
    row "4.1" "a 101 speaking none, when one was asked for, fails"
      ~protocol:named upgrade "failed: a 101 speaking another protocol";
    row "4.1" "a 101 speaking the protocol asked for opens it" ~protocol:named
      (upgrade ~extra:"Sec-WebSocket-Protocol: chat\r\n")
      "opened";
    row "4.1" "a 101 naming an extension nobody offered fails"
      (upgrade ~extra:"Sec-WebSocket-Extensions: permessage-deflate\r\n")
      "failed: an extension this client never offered";
  ]

(* ------------------------------------------------------------------ *)
(* At any cut *)

module G = QCheck.Gen

let gen_cuts n = G.(list_size (int_bound 8) (int_bound (max 1 n)))

let test_every_row_holds_at_any_cut () =
  let rows = Array.of_list server_rows in
  QCheck.Test.check_exn
    (QCheck.Test.make ~count:300 ~name:"a server row, at any cut"
       (QCheck.make
          ~print:(fun (i, cuts) ->
            let (r : row) = rows.(i) in
            Printf.sprintf "%s: %s, %s" r.rfc r.says (delivery_name (At cuts)))
          G.(
            int_bound (Array.length rows - 1) >>= fun i ->
            map
              (fun cuts -> (i, cuts))
              (gen_cuts (String.length rows.(i).sends))))
       (fun (i, cuts) ->
         check_server rows.(i) (At cuts);
         true));
  let rows = Array.of_list client_rows in
  QCheck.Test.check_exn
    (QCheck.Test.make ~count:200 ~name:"a client row, at any cut"
       (QCheck.make
          ~print:(fun (i, cuts) ->
            let r = rows.(i) in
            Printf.sprintf "%s: %s, %s" r.c_rfc r.c_says
              (delivery_name (At cuts)))
          G.(
            int_bound (Array.length rows - 1) >>= fun i ->
            map
              (fun cuts -> (i, cuts))
              (gen_cuts (String.length rows.(i).hears))))
       (fun (i, cuts) ->
         check_client rows.(i) (At cuts);
         true))

let () =
  Eio_main.run @@ fun env ->
  let each check rows name_of =
    List.concat_map
      (fun r ->
        List.map
          (fun d ->
            Alcotest.test_case
              (name_of r ^ ", " ^ delivery_name d)
              `Quick
              (fun () -> check r d))
          [ Whole; Bytewise ])
      rows
  in
  Alcotest.run "websocket_rfc"
    [
      ( "a server's frames",
        each check_server server_rows (fun (r : row) -> r.rfc ^ " " ^ r.says)
        @ [
            Alcotest.test_case "5.2 a length is written in the fewest bytes"
              `Quick test_a_length_is_written_in_the_fewest_bytes;
          ] );
      ( "a client's frames",
        each check_client client_rows (fun r -> r.c_rfc ^ " " ^ r.c_says)
        @ [
            Alcotest.test_case "5.5 a close sends no reason it cannot carry"
              `Quick test_a_close_sends_no_reason_it_cannot_carry;
            Alcotest.test_case "5.3 a mask of another length writes nothing"
              `Quick test_a_mask_of_another_length_writes_nothing;
          ] );
      ( "a server's handshake",
        List.map
          (fun (r : handshake_row) ->
            Alcotest.test_case
              (r.h_rfc ^ " " ^ r.h_says)
              `Quick (check_handshake r))
          handshake_rows );
      ( "a client's handshake",
        Alcotest.test_case "4.1 a client asks as the RFC says" `Quick
          (test_a_client_asks_as_the_rfc_says env)
        :: Alcotest.test_case "10.3 a key is fresh every time" `Quick
             (test_a_key_is_fresh_every_time env)
        :: client_handshake_rows env );
      ( "at any cut",
        [
          Alcotest.test_case "every row holds at any cut" `Quick
            test_every_row_holds_at_any_cut;
        ] );
    ]
