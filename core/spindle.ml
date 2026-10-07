module Status = Spindle_http.Status
module Meth = Spindle_http.Meth
module Codec = Codec

module Cookie = struct
  include Cookie

  (* A sealed cookie that does not open is absent, never an error: a browser
     holding one from a retired key did nothing wrong. Described as the
     string the browser holds. *)
  let sealed_input ~required c =
    let name = Cookie.Named.name c and codec = Cookie.Named.codec c in
    Dep.of_request
      ~needs:
        [
          Dep.Cookie
            { name; required; many = false; shape = Codec.String; kind = None };
        ]
      (fun r ->
        let absent () =
          if required then Error (Input.missing ~at:("cookie." ^ name))
          else Ok None
        in
        match Request.cookie r name with
        | None -> absent ()
        | Some raw -> (
            match
              Option.bind
                (Cookie.Named.unseal c ~now:(Request.now r) raw)
                (Codec.parse codec)
            with
            | Some v -> Ok (Some v)
            | None ->
                Logs.debug ~src:Log.http (fun m ->
                    m "the cookie %s did not open, and is read as absent" name);
                absent ()))

  let optional c =
    if Cookie.Named.sealed c then sealed_input ~required:false c
    else
      Input.optional Input.cookie (Cookie.Named.name c) (Cookie.Named.codec c)

  let required c =
    if Cookie.Named.sealed c then
      Dep.join
        (Dep.map
           (function
             | Some v -> Ok v
             | None ->
                 Error (Input.missing ~at:("cookie." ^ Cookie.Named.name c)))
           (sealed_input ~required:true c))
    else
      Input.required Input.cookie (Cookie.Named.name c) (Cookie.Named.codec c)

  let encoded =
    Codec.custom ~kind:"encoded" ~expects:"a value this server wrote"
      ~parse:Cookie_repr.decode ~print:Cookie_repr.encode ()
end

(* Binding operators only, so opening it brings no other name into scope. *)
module Syntax = struct
  let ( let+ ) d f = Dep.map f d
  let ( and+ ) = Dep.both
end

module Request = Request
module Refusal = Refusal
module Key = Key
module Session = Session
module Cors = Cors
module Compress = Compress
module Rate = Rate
module Response = Response
module Event = Event
module Websocket = Spindle_http.Websocket
module Returns = Returns
module Meta = Meta
module Dep = Dep
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
let peer = Dep.of_request ~needs:[] (fun r -> Ok (Request.peer r))
let client = Dep.of_request ~needs:[] (fun r -> Ok (Request.client r))
let request_id = Dep.of_request ~needs:[] (fun r -> Ok (Request.id r))
let body = Dep.of_body ~need:Dep.Raw (fun s -> Ok s)

let body_stream ?content_type ~max () : Body.t Dep.t =
  let codes =
    match content_type with
    | Some _ -> [ Refusal.Code.unsupported_media_type ]
    | None -> []
  in
  Dep_repr.make ~codes ~needs:[ Body Stream ] (fun (c : Dep_repr.context) ->
      match (content_type, Request.header c.request "content-type") with
      | Some accepts, Some named when not (accepts named) ->
          Now (Error Refusal.unsupported_media_type)
      | (Some _ | None), (Some _ | None) ->
          Later (fun held -> Ok (Body_repr.stream held ~max)))

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

(* A function, so a route that sets nothing never mentions it. *)
let outgoing_setter f : _ Dep.t =
  Dep_repr.make (fun (c : Dep_repr.context) ->
      Now
        (Ok
           (fun v ->
             let o = c.outgoing in
             if o.sent then
               L.warn (fun m ->
                   m
                     "%s set a cookie or a header after its answer had gone, \
                      which changed nothing"
                     o.pattern)
             else f o v)))

let set_cookie =
  outgoing_setter (fun (o : Dep_repr.outgoing) c ->
      o.cookies <- o.cookies @ [ c ])

let add_header =
  outgoing_setter (fun (o : Dep_repr.outgoing) h ->
      o.headers <- o.headers @ [ h ])

(* application/json or application/...+json; RFC 8259 §11 defines no
   parameters. Anything else is refused because a browser posts text/plain
   or a form cross-site without a preflight, and JSON only with one. *)
let is_json content_type =
  match Spindle_http.Media_type.parse content_type with
  | Ok { type_ = "application"; subtype; parameters = _ } ->
      String.equal subtype "json" || String.ends_with ~suffix:"+json" subtype
  | Ok _ | Error _ -> false

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
  Dep.of_body ~content_type:is_json
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

let epoch_ms clock () = int_of_float (Eio.Time.now clock *. 1000.)

(* A route table [App.make] refuses is a constant in source, so it raises:
   the program ends before it listens, saying why. *)
let serve ?(port = 8080) ?host ?domains ?middleware ?codes ?not_found ?cors
    ?compress ?check_origin ?trusted_origins ?trailing_slash ?now ?max_body
    ?max_header_bytes ?head_timeout_s ?idle_timeout_s ?body_timeout_s
    ?min_body_rate ?send_timeout_s ?discard_limit ?linger_s ?body_budget
    ?trusted_proxies ?proxy_header ?backlog ?max_connections ?stop ?drain_s
    ?on_stop ?ready ?trace ?metrics env routes =
  let app =
    match
      App.make ?middleware ?codes ?not_found ?cors ?compress ?check_origin
        ?trusted_origins ?trailing_slash routes
    with
    | Ok app -> app
    | Error m -> invalid_arg ("Spindle.serve: " ^ m)
  in
  (* The exit status is what an orchestrator sees; the reason is logged. *)
  (match App.start app ~fs:(Eio.Stdenv.fs env) with
  | Ok () -> ()
  | Error m ->
      L.err (fun f -> f "cannot start: %s" m);
      exit 1);
  Eio.Switch.run @@ fun sw ->
  let now = Option.value now ~default:(epoch_ms (Eio.Stdenv.clock env)) in
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
  Server.run ~sw ~net:(Eio.Stdenv.net env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~now
    ~domain_mgr:(Eio.Stdenv.domain_mgr env)
    ?domains ~port ?host ?max_body ?max_header_bytes ?head_timeout_s
    ?idle_timeout_s ?body_timeout_s ?min_body_rate ?send_timeout_s
    ?discard_limit ?linger_s ?body_budget ?trusted_proxies ?proxy_header
    ?backlog ?max_connections ~stop ?drain_s ?on_stop ~ready ?trace ?metrics app
