module Status = Spindle_http.Status
module Meth = Spindle_http.Meth

module Cookie = struct
  include Cookie

  (* A cookie that does not read is absent, never an error: the server wrote
     it and the browser only kept it, so one from a retired key, an older
     deploy or a script that broke its escape is no mistake of the person's.
     A sealed one is described as the string the browser holds, and reads
     the server's keys; a plain one is described by its description. *)
  let input ~required c =
    let name = Cookie.Named.name c
    and description = Cookie.Named.description c in
    let sealed = Cookie.Named.sealed c in
    let at = "cookie." ^ name in
    let carried =
      Dep.of_request
        ~needs:
          [
            Dep.Cookie
              {
                name;
                required;
                many = false;
                schema =
                  (if sealed then Parameter.schema Wiretype.string
                   else Parameter.schema description);
                kind = (if sealed then None else Parameter.kind description);
                default = None;
              };
          ]
        (fun r -> Ok (Request.cookie r name, Request.now r))
    and keys =
      if sealed then Dep.map Option.some Dep_repr.cookie_keys
      else Dep.return None
    in
    Dep.join
      (Dep.map
         (fun ((raw, now), keys) ->
           let absent () =
             if required then Error (Input.missing ~at) else Ok None
           in
           match raw with
           | None -> absent ()
           | Some raw -> (
               let opened =
                 match keys with
                 | Some keys -> Cookie.Named.unseal c ~keys ~now raw
                 | None -> Cookie_repr.unescape raw
               in
               match
                 Option.bind opened (fun v ->
                     Result.to_option (Input.parse ~at description v))
               with
               | Some v -> Ok (Some v)
               | None ->
                   Logs.debug ~src:Log.http (fun m ->
                       m "the cookie %s did not read, and is read as absent"
                         name);
                   absent ()))
         (Dep.both carried keys))

  let optional c = input ~required:false c

  let required c =
    Dep.join
      (Dep.map
         (function
           | Some v -> Ok v
           | None -> Error (Input.missing ~at:("cookie." ^ Cookie.Named.name c)))
         (input ~required:true c))
end

(* Binding operators only, so opening it brings no other name into scope. *)
module Syntax = struct
  let ( let+ ) d f = Dep.map f d
  let ( and+ ) = Dep.both
  let ( let* ) = Result.bind
end

module Request = Request
module Refusal = Refusal
module Key = Key
module Session = Session
module Cors = Cors
module Compress = Compress
module Cache = Cache
module Rate = Rate
module Response = Response
module Event = Event
module Websocket = Spindle_http.Websocket
module Returns = Returns
module Meta = Meta
module Dep = Dep
module Bearer = Bearer
module Query = Query
module Form = Form
module Header = Header
module Path = Path
module Route = Route
module Middleware = Middleware
module App = App
module Server = Server
module Test = Test
module Log = Log
module Trace = Spindle_http.Trace
module Metrics = Metrics
module Local = Spindle_http.Local
module Background = Background
module Alarm = Alarm
module Broadcast = Broadcast
module Body = Body
module Multipart = Multipart
module Static = Static
module Files = Files
module Openapi = Openapi
module Health = Health
module Zod = Zod
module Melange = Melange

let blocking f = Eio_unix.run_in_systhread (Log.carry f)
let route = Route_repr.make
let get = Route_repr.get
let post = Route_repr.post
let put = Route_repr.put
let patch = Route_repr.patch
let delete = Route_repr.delete
let param = Input.param

(* Reads anything, so it declares no needs. *)
let request = Dep.of_request (fun r -> Ok r)
let now = Dep.of_request ~needs:[] (fun r -> Ok (Request.now r))
let keys = Dep_repr.cookie_keys
let peer = Dep.of_request ~needs:[] (fun r -> Ok (Request.peer r))
let client_ip = Dep.of_request ~needs:[] (fun r -> Ok (Request.client_ip r))
let request_id = Dep.of_request ~needs:[] (fun r -> Ok (Request.id r))
let client_gone = Dep.of_request ~needs:[] (fun r -> Ok (Request.client_gone r))
let body = Dep.of_body (fun s -> Ok s)

let body_stream ?(content_types = []) ~max () : Body.t Dep.t =
  let codes =
    match content_types with
    | [] -> []
    | _ :: _ -> [ Refusal.Code.unsupported_media_type ]
  in
  Dep_repr.make ~codes
    ~needs:[ Body (Stream { content_types }) ]
    (fun (c : Dep_repr.context) ->
      if not (Dep_repr.takes_content_type content_types c.request) then
        Now (Error Refusal.unsupported_media_type)
      else Later (fun held -> Ok (Body_repr.stream held ~max)))

(* The content type is checked before the body is read. *)
let multipart ?max_head ~max () : Multipart.t Dep.t =
  Dep_repr.make ~needs:[ Body Multipart ]
    ~codes:[ Refusal.Code.unsupported_media_type ]
    (fun (c : Dep_repr.context) ->
      match
        Option.map Spindle_http.Media_type.parse
          (Request.header c.request "content-type")
      with
      | Some (Ok ({ type_ = "multipart"; subtype = "form-data"; _ } as m)) -> (
          match Spindle_http.Multipart.boundary m with
          | Some boundary ->
              Later
                (fun held ->
                  let body = Body_repr.stream held ~max in
                  Ok
                    (Spindle_http.Multipart.create ?max_head ~boundary
                       (fun () ->
                         match Body.read body with
                         | Ok (`Data s) -> Ok (Some s)
                         | Ok `End -> Ok None
                         | Error e -> Error e)))
          | None ->
              Now
                (Error
                   (Dep.problem ~at:"header.content-type" ~code:"malformed"
                      "This names no boundary.")))
      | Some (Ok _ | Error _) | None ->
          Now (Error Refusal.unsupported_media_type))

module L = (val Logs.src_log Log.http : Logs.LOG)

let set_cookie = Outgoing.set_cookie
let add_header = Outgoing.add_header

(* Each at its path as a client writes it, [body.items[2].count]. *)
let body_problems problems =
  List.map
    (fun (p : Wiretype.Problem.t) ->
      {
        Refusal.at = Wiretype.Problem.path ~root:"body" p.at;
        code = Wiretype.Problem.code_to_string p.code;
        message = p.message;
      })
    problems

let json ?refusal ?(examples = []) t =
  Dep_repr.of_body
    ?refuses:(Option.map (fun (code, _) -> [ code ]) refusal)
    ~need:(Dep.Json { description = t; examples })
    (fun s ->
      let s = if String.equal (String.trim s) "" then "{}" else s in
      match Wiretype.decode t s with
      | Ok v -> Ok v
      | Error problems -> (
          match refusal with
          | Some (code, sentence) ->
              let detail =
                String.concat "; "
                  (List.map Wiretype.Problem.to_string problems)
              in
              Error (Refusal.make ~detail code sentence)
          | None -> Error (Refusal.invalid (body_problems problems))))

let of_clock = Spindle_http.Instant.of_clock
let until = Spindle_http.Instant.until

(* A route table [App.make] refuses is a constant in source, so it raises:
   the program ends before it listens, saying why. *)
let serve ?(port = 8080) ?host ?domains ?resources ?middleware ?refuses
    ?not_found ?cors ?compress ?check_origin ?trusted_origins ?trailing_slash
    ?read_clock ?limits ?trusted_proxies ?proxy_header ?stop ?on_stop ?ready
    ?trace ?metrics ?keys env routes =
  let app =
    match
      App.make ?middleware ?refuses ?not_found ?cors ?compress ?check_origin
        ?trusted_origins ?trailing_slash routes
    with
    | Ok app -> app
    | Error m -> invalid_arg ("Spindle.serve: " ^ m)
  in
  (* The exit status is what an orchestrator sees, and the reason is logged --
     or written to stderr where the program set no log up, since Logs drops
     every line until a reporter is set. *)
  let stop_because why =
    if Logs.reporter () == Logs.nop_reporter then prerr_endline why
    else L.err (fun f -> f "%s" why);
    exit 1
  in
  let instance =
    match
      App.start ?resources ?keys app ~fs:(Eio.Stdenv.fs env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
    with
    | Ok instance -> instance
    | Error m -> stop_because ("cannot start: " ^ m)
  in
  Eio.Switch.run @@ fun sw ->
  let read_clock =
    match read_clock with
    | Some read -> read
    | None -> fun () -> of_clock (Eio.Stdenv.clock env)
  in
  let stop =
    match stop with Some s -> s | None -> Server.stop_on_signals ~sw ()
  in
  let ready =
    let host = Option.value host ~default:"localhost" in
    let authority =
      if String.contains host ':' then Printf.sprintf "[%s]:%d" host port
      else Printf.sprintf "%s:%d" host port
    in
    Option.value ready ~default:(fun where ->
        Printf.printf "Listening on http://%s (%s)\n%!" authority where)
  in
  match
    Server.run ~sw ~net:(Eio.Stdenv.net env)
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~read_clock
      ~domain_mgr:(Eio.Stdenv.domain_mgr env)
      ?domains ~port ?host ?limits ?trusted_proxies ?proxy_header ~stop ?on_stop
      ~ready ?trace ?metrics instance
  with
  | Ok () -> ()
  | Error e -> stop_because (Server.listen_error_to_string e)
