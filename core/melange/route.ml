(* ---- Calling the routes ---- *)

(* What every printed route calls through: the browser's fetch, a request
   checked whole before it goes, and an answer read by what the route says it
   answers. It is Melange over fetch, Js.Json and Js.Dict alone, so a printed
   client needs no library. *)

(** A call to a route, and what can come of it. *)
module Route = struct
  type error =
    [ `Invalid of Problem.t list
      (** an input is not what the route reads: every problem, at the
          parameter's name or the body's own path, and nothing was sent *)
    | `Lost of string
      (** no answer came back: the network failed, or the request was stopped,
          and it may or may not have reached the server *)
    | `Refused of refusal  (** the server's refusal: its code and sentence *)
    | `Unexpected of string
      (** an answer the route does not say it gives: a status it never answers,
          a body its description does not read, or a failure with no refusal in
          it. In words for the console. *) ]

  let error_to_string = function
    | `Invalid problems ->
        "the input is not what the route reads: "
        ^ String.concat "; " (List.map Problem.to_string problems)
    | `Lost message -> message
    | `Refused (r : refusal) -> r.error ^ ": " ^ r.message
    | `Unexpected message -> message

  type response
  type init
  type body
  type form
  type abort_controller
  type signal

  external fetch : string -> init -> response Js.Promise.t = "fetch"

  external init :
    meth:(string[@mel.as "method"]) ->
    headers:string Js.Dict.t ->
    ?body:body ->
    ?signal:signal ->
    unit ->
    init = ""
  [@@mel.obj]

  external abort_controller : unit -> abort_controller = "AbortController"
  [@@mel.new]

  external signal : abort_controller -> signal = "signal" [@@mel.get]
  external abort : abort_controller -> unit = "abort" [@@mel.send]
  external status : response -> int = "status" [@@mel.get]
  external text_of : response -> string Js.Promise.t = "text" [@@mel.send]
  external text_body : string -> body = "%identity"
  external form_body : form -> body = "%identity"
  external form : unit -> form = "FormData" [@@mel.new]
  external append : form -> string -> string -> unit = "append" [@@mel.send]

  external append_file : form -> string -> Js.File.t -> unit = "append"
  [@@mel.send]

  external encode_uri_component : string -> string = "encodeURIComponent"
  external js_string : Js.Promise.error -> string = "String"

  (* A problem in a parameter is reported at its name, as the server
     reports it. *)
  let at name (p : Problem.t) =
    let at =
      match p.at with
      | "" -> name
      | a when String.get a 0 = '[' -> name ^ a
      | a -> name ^ "." ^ a
    in
    { p with at }

  let named name = Result.map_error (List.map (at name))

  (* A parameter's value as the text a path, a query or a header carries: a
     list's items each its own. *)
  let rec texts j =
    match Js.Json.classify j with
    | JSONString s -> [ s ]
    | JSONNumber _ | JSONTrue | JSONFalse -> [ Js.Json.stringify j ]
    | JSONArray items -> List.concat_map texts (Array.to_list items)
    | JSONNull | JSONObject _ -> []

  let literal s = Ok s

  let segment name value =
    Result.map
      (fun j -> String.concat "," (List.map encode_uri_component (texts j)))
      (named name value)

  let query name = function
    | None -> Ok []
    | Some value ->
        Result.map
          (fun j ->
            List.map
              (fun t ->
                encode_uri_component name ^ "=" ^ encode_uri_component t)
              (texts j))
          (named name value)

  let header name = function
    | None -> Ok []
    | Some value ->
        Result.map
          (fun j -> [ (name, String.concat ", " (texts j)) ])
          (named name value)

  type payload = { content_type : string option; body : body option }

  let no_body = Ok { content_type = None; body = None }

  let json = function
    | None -> no_body
    | Some encoded ->
        Result.map
          (fun s ->
            {
              content_type = Some "application/json";
              body = Some (text_body s);
            })
          encoded

  let raw ~content_type = function
    | None -> no_body
    | Some s ->
        Ok { content_type = Some content_type; body = Some (text_body s) }

  (* A form is sent as FormData, which the browser frames as multipart and
     which carries a file beside the fields. *)
  let form fields files =
    Result.map
      (fun j ->
        let f = form () in
        (match Js.Json.classify j with
        | JSONObject members ->
            Array.iter
              (fun (name, value) ->
                List.iter (fun t -> append f name t) (texts value))
              (Js.Dict.entries members)
        | _ -> ());
        List.iter
          (fun (name, each) -> List.iter (append_file f name) each)
          files;
        { content_type = None; body = Some (form_body f) })
      fields

  type 'a answer = { gives : int -> bool; read : string -> ('a, string) result }

  let value statuses decode =
    {
      gives = (fun s -> List.mem s statuses);
      read =
        (fun text ->
          Result.map_error
            (fun problems ->
              "an answer its description does not read: "
              ^ String.concat "; " (List.map Problem.to_string problems))
            (decode text));
    }

  let empty statuses =
    { gives = (fun s -> List.mem s statuses); read = (fun _ -> Ok ()) }

  let text_answer =
    { gives = (fun s -> s >= 200 && s < 300); read = (fun text -> Ok text) }

  let answered answer ~where status text =
    if answer.gives status then
      Result.map_error
        (fun m -> `Unexpected (where ^ " answered " ^ m))
        (answer.read text)
    else if status >= 400 then
      match decode_refusal text with
      | Ok r -> Error (`Refused r)
      | Error _ ->
          Error
            (`Unexpected
               (where ^ " answered " ^ string_of_int status
              ^ " with no refusal in it"))
    else
      Error
        (`Unexpected
           (where ^ " answered " ^ string_of_int status
          ^ ", a status it never gives"))

  let all checked =
    let problems =
      List.concat_map (function Ok _ -> [] | Error ps -> ps) checked
    in
    match problems with
    | [] -> Ok (List.filter_map Result.to_option checked)
    | _ :: _ -> Error problems

  (* A request checked whole: its URL, its fields and its body, or every
     problem its inputs have. *)
  let request ~origin ~path ~query ~headers ~body =
    match (all path, all query, all headers, body) with
    | Ok path, Ok query, Ok headers, Ok (payload : payload) ->
        let query = List.concat query in
        let url =
          origin ^ String.concat "" path
          ^ match query with [] -> "" | q -> "?" ^ String.concat "&" q
        in
        let headers =
          List.concat headers
          @ Option.fold ~none:[]
              ~some:(fun t -> [ ("content-type", t) ])
              payload.content_type
        in
        Ok (url, headers, payload.body)
    | path, query, headers, body ->
        let problems = function Ok _ -> [] | Error ps -> ps in
        Error
          (`Invalid
             (problems path @ problems query @ problems headers @ problems body))

  (* [route] is the route as the server names it, [GET /items/{key}], for
     the words of an error. *)
  let call ?(origin = "") ~route ~meth ~path ~query ~headers ~body answer :
      ('a, error) result Js.Promise.t =
    match request ~origin ~path ~query ~headers ~body with
    | Error e -> Js.Promise.resolve (Error e)
    | Ok (url, headers, body) ->
        Js.Promise.(
          fetch url (init ~meth ~headers:(Js.Dict.fromList headers) ?body ())
          |> then_ (fun r ->
              text_of r |> then_ (fun text -> resolve (Ok (status r, text))))
          |> catch (fun e ->
              resolve (Error (`Lost (route ^ " had no answer: " ^ js_string e))))
          |> then_ (fun got ->
              resolve
                (match got with
                | Ok (status, text) -> answered answer ~where:route status text
                | Error e -> Error e)))

  (* A failure an answer's status says, where the route answers a stream or
     a socket: its refusal, or what it is instead. *)
  let refused ~where status text =
    match decode_refusal text with
    | Ok r when status >= 400 -> Error (`Refused r)
    | Ok _ | Error _ ->
        Error
          (`Unexpected
             (where ^ " answered " ^ string_of_int status
            ^ ", where it answers a stream"))

  (** A route's events as they arrive, read over fetch, so a refusal is read as
      any route's is. Nothing reconnects: a stream that ends is the caller's to
      call again. *)
  module Stream = struct
    type t = {
      controller : abort_controller;
      closed : bool ref;
      ended : (unit, error) result Js.Promise.t;
    }

    let close t =
      if not !(t.closed) then (
        t.closed := true;
        abort t.controller)

    let ended t = t.ended

    (* An event's data, read by its component's decoder. *)
    let json decode wrap data =
      Result.map wrap
        (Result.map_error
           (fun problems ->
             "data its description does not read: "
             ^ String.concat "; " (List.map Problem.to_string problems))
           (decode data))

    type stream
    type reader
    type chunk
    type decoder

    external response_body : response -> stream = "body" [@@mel.get]
    external get_reader : stream -> reader = "getReader" [@@mel.send]
    external read_chunk : reader -> chunk Js.Promise.t = "read" [@@mel.send]
    external is_done : chunk -> bool = "done" [@@mel.get]

    external chunk_value : chunk -> Js.Typed_array.Uint8Array.t = "value"
    [@@mel.get]

    external decoder : unit -> decoder = "TextDecoder" [@@mel.new]

    external decode :
      decoder ->
      Js.Typed_array.Uint8Array.t ->
      (_[@mel.as {json|{"stream":true}|json}]) ->
      string = "decode"
    [@@mel.send]

    (* An event stream's fields as the server writes them and the HTML
       standard reads them: a blank line ends an event, [event:] names it,
       each [data:] line is a line of its data, and a line from [:] is a
       comment. *)
    type parser = {
      mutable pending : string;
      mutable after_cr : bool;
      mutable name : string;
      mutable data : string list;
    }

    let parser () = { pending = ""; after_cr = false; name = ""; data = [] }

    let field p line =
      if String.equal line "" then (
        let data = List.rev p.data and name = p.name in
        p.data <- [];
        p.name <- "";
        match data with
        | [] -> None
        | _ :: _ ->
            Some
              ( (if String.equal name "" then "message" else name),
                String.concat "\n" data ))
      else if String.get line 0 = ':' then None
      else
        let name, value =
          match String.index_opt line ':' with
          | None -> (line, "")
          | Some i ->
              let v = String.sub line (i + 1) (String.length line - i - 1) in
              ( String.sub line 0 i,
                if String.length v > 0 && String.get v 0 = ' ' then
                  String.sub v 1 (String.length v - 1)
                else v )
        in
        (match name with
        | "event" -> p.name <- value
        | "data" -> p.data <- value :: p.data
        | _ -> ());
        None

    (* Each event the text completes, a line ending in CR, LF or both. *)
    let feed p text =
      let events = ref [] and start = ref 0 in
      let text = p.pending ^ text in
      String.iteri
        (fun i ch ->
          if ch = '\n' && p.after_cr && i = !start then start := i + 1
          else if ch = '\n' || ch = '\r' then (
            Option.iter
              (fun e -> events := e :: !events)
              (field p (String.sub text !start (i - !start)));
            start := i + 1);
          p.after_cr <- ch = '\r')
        text;
      p.pending <- String.sub text !start (String.length text - !start);
      List.rev !events

    let call ?(origin = "") ~route ~meth ~path ~query ~headers ~body ~read
        ~on_event () =
      let controller = abort_controller () and closed = ref false in
      let ended =
        match request ~origin ~path ~query ~headers ~body with
        | Error e ->
            closed := true;
            Js.Promise.resolve (Error e)
        | Ok (url, headers, body) ->
            let headers = ("accept", "text/event-stream") :: headers in
            let failed e =
              closed := true;
              abort controller;
              Js.Promise.resolve (Error e)
            in
            let rec pump reader p decoder =
              Js.Promise.then_
                (fun chunk ->
                  if is_done chunk then Js.Promise.resolve (Ok ())
                  else
                    let events = feed p (decode decoder (chunk_value chunk)) in
                    let rec deliver = function
                      | [] -> pump reader p decoder
                      | (name, data) :: rest -> (
                          match read name data with
                          | Ok event ->
                              on_event event;
                              if !closed then Js.Promise.resolve (Ok ())
                              else deliver rest
                          | Error m ->
                              failed
                                (`Unexpected (route ^ " sent " ^ name ^ ", " ^ m))
                          )
                    in
                    deliver events)
                (read_chunk reader)
            in
            Js.Promise.(
              fetch url
                (init ~meth ~headers:(Js.Dict.fromList headers) ?body
                   ~signal:(signal controller) ())
              |> then_ (fun r ->
                  if status r = 200 then
                    pump (get_reader (response_body r)) (parser ()) (decoder ())
                  else
                    text_of r
                    |> then_ (fun text ->
                        resolve (refused ~where:route (status r) text)))
              |> catch (fun e ->
                  resolve
                    (if !closed then Ok ()
                     else
                       Error
                         (`Lost (route ^ " stopped answering: " ^ js_string e)))))
      in
      { controller; closed; ended }
  end

  (** A WebSocket to a route: what the server sends handed over as it comes,
      typed by the route, and what is sent typed and checked before it goes. *)
  module Socket = struct
    type websocket
    type message_event
    type close_event
    type frame = Text of string | Binary of Js.Typed_array.ArrayBuffer.t

    type 'client t = {
      ws : websocket option;
      write : 'client -> (frame, Problem.t list) result;
      mutable queued : frame list;  (** what was sent before it opened *)
      closed : bool ref;
      ended : (unit, error) result Js.Promise.t;
    }

    external websocket : string -> string array -> websocket = "WebSocket"
    [@@mel.new]

    external set_binary_type : websocket -> string -> unit = "binaryType"
    [@@mel.set]

    external ready_state : websocket -> int = "readyState" [@@mel.get]
    external send_text : websocket -> string -> unit = "send" [@@mel.send]

    external send_binary : websocket -> Js.Typed_array.ArrayBuffer.t -> unit
      = "send"
    [@@mel.send]

    external close_ws : websocket -> unit = "close" [@@mel.send]

    external set_on_open : websocket -> (unit -> unit) -> unit = "onopen"
    [@@mel.set]

    external set_on_message : websocket -> (message_event -> unit) -> unit
      = "onmessage"
    [@@mel.set]

    external set_on_close : websocket -> (close_event -> unit) -> unit
      = "onclose"
    [@@mel.set]

    external message_data : message_event -> Js.Json.t = "data" [@@mel.get]
    external as_text : Js.Json.t -> string = "%identity"
    external as_bytes : Js.Json.t -> Js.Typed_array.ArrayBuffer.t = "%identity"
    external close_code : close_event -> int = "code" [@@mel.get]
    external close_reason : close_event -> string = "reason" [@@mel.get]
    external new_url : string -> string -> Js.Json.t = "URL" [@@mel.new]
    external url_protocol : Js.Json.t -> string = "protocol" [@@mel.get]

    external set_url_protocol : Js.Json.t -> string -> unit = "protocol"
    [@@mel.set]

    external url_href : Js.Json.t -> string = "href" [@@mel.get]
    external page : string = "href" [@@mel.scope "location"]

    (* An origin's http as ws and https as wss; the page's own where none is
       given. *)
    let ws_url ~origin url =
      let u = new_url url (if String.equal origin "" then page else origin) in
      set_url_protocol u
        (if String.equal (url_protocol u) "https:" then "wss:" else "ws:");
      url_href u

    let put ws = function
      | Text s -> send_text ws s
      | Binary b -> send_binary ws b

    let send t message =
      match (t.ws, t.write message) with
      | _, Error problems -> Error (`Invalid problems)
      | None, Ok _ -> Error (`Lost "the socket was never opened")
      | Some ws, Ok frame -> (
          match ready_state ws with
          | 0 ->
              t.queued <- t.queued @ [ frame ];
              Ok ()
          | 1 ->
              put ws frame;
              Ok ()
          | _ -> Error (`Lost "the socket is closed"))

    let close t =
      t.closed := true;
      Option.iter close_ws t.ws

    let ended t = t.ended
    let json_out encode v = Result.map (fun s -> Text s) (encode v)
    let text_out s = Ok (Text s)
    let binary_out b = Ok (Binary b)

    let json_in decode = function
      | Text s ->
          Result.map_error
            (fun problems ->
              "a message its description does not read: "
              ^ String.concat "; " (List.map Problem.to_string problems))
            (decode s)
      | Binary _ -> Error "bytes, where it sends JSON"

    let text_in = function
      | Text s -> Ok s
      | Binary _ -> Error "bytes, where it sends text"

    let binary_in = function
      | Binary b -> Ok b
      | Text _ -> Error "text, where it sends bytes"

    let call ?(origin = "") ~route ~path ~query ?subprotocol ~write ~read
        ~on_message () =
      match request ~origin:"" ~path ~query ~headers:[] ~body:no_body with
      | Error e ->
          {
            ws = None;
            write;
            queued = [];
            closed = ref true;
            ended = Js.Promise.resolve (Error e);
          }
      | Ok (url, _, _) ->
          let ws =
            websocket (ws_url ~origin url)
              (match subprotocol with Some p -> [| p |] | None -> [||])
          in
          set_binary_type ws "arraybuffer";
          let closed = ref false and failure = ref None in
          let ended =
            Js.Promise.make (fun ~resolve ~reject:_ ->
                set_on_close ws (fun e ->
                    let result =
                      match !failure with
                      | Some f -> Error f
                      | None ->
                          if !closed || close_code e = 1000 then Ok ()
                          else
                            Error
                              (`Lost
                                 (route ^ " closed with "
                                 ^ string_of_int (close_code e)
                                 ^
                                 match close_reason e with
                                 | "" -> ""
                                 | r -> ": " ^ r))
                    in
                    (resolve result [@u])))
          in
          let t = { ws = Some ws; write; queued = []; closed; ended } in
          set_on_open ws (fun () ->
              List.iter (put ws) t.queued;
              t.queued <- []);
          set_on_message ws (fun e ->
              let data = message_data e in
              let frame =
                if Js.typeof data = "string" then Text (as_text data)
                else Binary (as_bytes data)
              in
              match read frame with
              | Ok message -> on_message message
              | Error m ->
                  failure := Some (`Unexpected (route ^ " sent " ^ m));
                  close t);
          t
  end
end
