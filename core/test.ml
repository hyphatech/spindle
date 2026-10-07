module Websocket = Spindle_http.Websocket
module Status = Spindle_http.Status
module Meth = Spindle_http.Meth

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

(* A route table [App.make] refuses is a constant in source, so a test stops
   on it as [Spindle.serve] does. *)
let app ?middleware ?codes ?not_found ?cors ?compress ?check_origin
    ?trusted_origins ?trailing_slash routes =
  match
    App.make ?middleware ?codes ?not_found ?cors ?compress ?check_origin
      ?trusted_origins ?trailing_slash routes
  with
  | Ok app -> (
      match
        List.find_opt (fun (r : Route_repr.t) -> Option.is_some r.start) routes
      with
      | None -> app
      | Some r ->
          invalid_arg
            (Printf.sprintf
               "Spindle.Test.app: %s %s reads a directory when the server \
                starts; a test loads it with Static.load and serves it with \
                Static.route"
               (Spindle_http.Meth.to_string r.info.meth)
               r.info.pattern))
  | Error m -> invalid_arg ("Spindle.Test.app: " ^ m)

(* The route's answer, refusing what it does not declare. *)
let answer_checked app req ~body =
  let r, (answered : App.answered) =
    Log.with_request_id ?traceparent:(Request.header req "traceparent")
      (Request.id req) (fun () -> App.handle app req ~body)
  in
  (let asked =
     Printf.sprintf "%s %s"
       (Meth.to_string (Request.meth req))
       (Request.target req)
   in
   match answered.undeclared with
   | Some (App.Code code) ->
       invalid_arg
         (Printf.sprintf "%s refused with %s, which nothing declares" asked
            (Refusal.Code.name code))
   | Some (App.Status status) ->
       invalid_arg
         (Printf.sprintf "%s answered %d, which its route does not list" asked
            (Spindle_http.Status.to_int status))
   | None -> ());
  Wire.render ?gzip:answered.gzip req r

(* What the server reads at once. *)
let part_bytes = 65_536

let call ?(now = 0) ?(peer = "127.0.0.1") ?proxied ?proxy_header ?version
    ?(headers = []) ?body app meth target =
  let req =
    Request.make ~peer ?proxied ?proxy_header ?version ~headers
      ~now:(fun () -> now)
      meth target
  in
  (* As the server hands it over: whole, or in parts, too large before any is
     read, as a declared length is. *)
  let body =
    let s = Option.value body ~default:"" and at = ref 0 in
    {
      Body.whole = (fun () -> Ok s);
      part =
        (fun ~max ->
          if String.length s > max then Error Body.Too_large
          else if !at >= String.length s then Ok `End
          else
            let n = Int.min part_bytes (String.length s - !at) in
            let part = String.sub s !at n in
            at := !at + n;
            Ok (`Data part));
    }
  in
  let wire = answer_checked app req ~body in
  {
    status = Status.to_int wire.status;
    headers = wire.headers;
    body =
      (match wire.body with
      | Wire.Nothing | Wire.Connection _ -> ""
      | Wire.Bytes s -> s
      (* Run to the end, so a stream that never ends never returns. *)
      | Wire.Chunks stream | Wire.Until_close stream ->
          (* As the server writes it: each send encoded where the app
             compresses the stream. *)
          let b = Buffer.create 256 in
          let encoder =
            Option.map (fun level -> Gzip.create ~level) wire.gzip
          in
          ignore
            (stream.produce (fun s ->
                 Buffer.add_string b
                   (match encoder with
                   | Some g when String.length s > 0 -> Gzip.write g s
                   | Some _ | None -> s);
                 Ok ())
              : (unit, Response.gone) result);
          Option.iter (fun g -> Buffer.add_string b (Gzip.finish g)) encoder;
          Buffer.contents b
      (* What the wire would carry: no byte past the length it said. *)
      | Wire.Counted (n, stream) ->
          let b = Buffer.create (min n part_bytes) in
          ignore
            (stream.produce (fun s ->
                 let room = n - Buffer.length b in
                 Buffer.add_string b
                   (String.sub s 0 (min room (String.length s)));
                 if String.length s > room then Error Response.Gone else Ok ())
              : (unit, Response.gone) result);
          Buffer.contents b);
  }

let no_body = { Body.whole = (fun () -> Ok ""); part = (fun ~max:_ -> Ok `End) }

(* ------------------------------------------------------------------ *)
(* A browser, keeping what the app set *)

module Browser = struct
  type cookie = {
    name : string;
    value : string;
    path : string;
    expires : int option;  (** the call's [now] past which it is dropped *)
  }

  type t = { app : App.t; mutable jar : cookie list }

  let path_of target =
    match String.index_opt target '?' with
    | Some i -> String.sub target 0 i
    | None -> target

  (* RFC 6265 §5.1.4: the request's path, or a directory of it. *)
  let path_matches ~cookie path =
    String.equal path cookie
    || String.starts_with ~prefix:cookie path
       && (String.ends_with ~suffix:"/" cookie
          || Char.equal path.[String.length cookie] '/')

  (* RFC 6265 §5.1.4's default path: the request's, up to its last slash. *)
  let default_path path =
    match String.rindex_opt path '/' with
    | Some 0 | None -> "/"
    | Some i -> String.sub path 0 i

  (* Its name and value, and the path and age among its attributes. *)
  let store_set_cookie ~now ~request_path jar header =
    match String.split_on_char ';' header with
    | [] -> jar
    | pair :: attributes -> (
        match String.index_opt pair '=' with
        | None -> jar
        | Some i ->
            let name = String.trim (String.sub pair 0 i)
            and value =
              String.trim (String.sub pair (i + 1) (String.length pair - i - 1))
            in
            let attribute key =
              List.find_map
                (fun a ->
                  match String.index_opt a '=' with
                  | Some j
                    when String.equal
                           (String.lowercase_ascii
                              (String.trim (String.sub a 0 j)))
                           key ->
                      Some
                        (String.trim
                           (String.sub a (j + 1) (String.length a - j - 1)))
                  | Some _ | None -> None)
                attributes
            in
            let path =
              Option.value (attribute "path")
                ~default:(default_path request_path)
            in
            let max_age = Option.bind (attribute "max-age") int_of_string_opt in
            let others =
              List.filter
                (fun c ->
                  not (String.equal c.name name && String.equal c.path path))
                jar
            in
            let deleted =
              String.equal value ""
              || match max_age with Some n -> n <= 0 | None -> false
            in
            if deleted then others
            else
              others
              @ [
                  {
                    name;
                    value;
                    path;
                    expires = Option.map (fun n -> now + (n * 1000)) max_age;
                  };
                ])

  let call ?(now = 0) ?peer ?(headers = []) ?body b meth target =
    b.jar <-
      List.filter
        (fun c -> match c.expires with Some e -> e > now | None -> true)
        b.jar;
    let path = path_of target in
    (* Longer paths first, as RFC 6265 §5.4 has a browser order them. *)
    let sending =
      List.stable_sort
        (fun a b -> Int.compare (String.length b.path) (String.length a.path))
        (List.filter (fun c -> path_matches ~cookie:c.path path) b.jar)
    in
    let headers =
      match sending with
      | [] -> headers
      | _ :: _ ->
          ( "cookie",
            String.concat "; "
              (List.map (fun c -> c.name ^ "=" ^ c.value) sending) )
          :: headers
    in
    let r = call ~now ?peer ~headers ?body b.app meth target in
    b.jar <-
      List.fold_left
        (fun jar (k, v) ->
          if String.equal (String.lowercase_ascii k) "set-cookie" then
            store_set_cookie ~now ~request_path:path jar v
          else jar)
        b.jar r.headers;
    r

  let cookies b = List.map (fun c -> (c.name, c.value)) b.jar
end

let browser app = { Browser.app; jar = [] }

(* ------------------------------------------------------------------ *)
(* An events route, read an event at a time *)

let events ?(now = 0) ?(headers = []) app target f =
  let req =
    Request.make ~peer:"127.0.0.1"
      ~headers:(("accept", "text/event-stream") :: headers)
      ~now:(fun () -> now)
      `GET target
  in
  let wire = answer_checked app req ~body:no_body in
  match wire.body with
  | Wire.Chunks stream | Wire.Until_close stream ->
      let reader = Spindle_http.Event_stream.reader () in
      let gone = ref false in
      let stopped, resolve_stopped = Eio.Promise.create () in
      (* Stopping is the client leaving: the next send is Gone, and a
         producer waiting to send is cancelled. *)
      let send s =
        if !gone then Error Response.Gone
        else (
          List.iter
            (fun e ->
              if not !gone then
                match f e with
                | `Continue -> ()
                | `Stop ->
                    gone := true;
                    Eio.Promise.resolve resolve_stopped ())
            (match Spindle_http.Event_stream.feed reader s with
            | Ok events -> events
            | Error m -> invalid_arg ("Spindle.Test.events: " ^ m));
          Ok ())
      in
      Eio.Fiber.first
        (fun () -> ignore (stream.produce send : (unit, Response.gone) result))
        (fun () -> Eio.Promise.await stopped);
      Ok ()
  | Wire.Nothing | Wire.Bytes _ | Wire.Counted _ | Wire.Connection _ ->
      Error
        {
          status = Status.to_int wire.status;
          headers = wire.headers;
          body = (match wire.body with Wire.Bytes s -> s | _ -> "");
        }

type websocket_error = Refused of response | Ended of Websocket.error

(* Over a socket pair, on a clock that never moves, so a keep-alive or a
   limit fires only in a test that moves it. *)
let websocket ?(now = 0) ?(headers = []) app protocol target f =
  let offered =
    match Websocket.subprotocol protocol with
    | Some n -> [ ("sec-websocket-protocol", n) ]
    | None -> []
  in
  let req =
    Request.make ~peer:"127.0.0.1"
      ~headers:
        (headers
        @ [
            ("host", "test");
            ("upgrade", "websocket");
            ("connection", "upgrade");
            ("sec-websocket-version", "13");
            ("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==");
          ]
        @ offered)
      ~now:(fun () -> now)
      `GET target
  in
  let wire = answer_checked app req ~body:no_body in
  match wire.body with
  | Wire.Connection handle ->
      Eio.Switch.run @@ fun sw ->
      let server, client = Eio_unix.Net.socketpair_stream ~sw () in
      let clock =
        (Eio_mock.Clock.Mono.make () :> Eio.Time.Mono.ty Eio.Resource.t)
      in
      let run_end flow run =
        Eio.Buf_write.with_flow flow (fun writer ->
            run
              {
                Response.reader = Eio.Buf_read.of_flow flow ~max_size:part_bytes;
                writer;
                clock;
                send_timeout_s = 10.;
                stopping = fst (Eio.Promise.create ());
              })
        |> fun result ->
        (try Eio.Flow.shutdown flow `All with Eio.Io _ -> ());
        result
      in
      let (), ended =
        Eio.Fiber.pair
          (fun () -> run_end server handle)
          (fun () ->
            run_end client (fun c ->
                Websocket.run_client
                  ~mask:(fun () -> "\x5a\xa5\x0f\xf0")
                  protocol c f))
      in
      Result.map_error (fun e -> Ended e) ended
  | Wire.Nothing | Wire.Bytes _ | Wire.Chunks _ | Wire.Counted _
  | Wire.Until_close _ ->
      Error
        (Refused
           {
             status = Status.to_int wire.status;
             headers = wire.headers;
             body = (match wire.body with Wire.Bytes s -> s | _ -> "");
           })

let header r name =
  List.assoc_opt
    (String.lowercase_ascii name)
    (List.map (fun (k, v) -> (String.lowercase_ascii k, v)) r.headers)
