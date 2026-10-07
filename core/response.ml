module Status = Spindle_http.Status

type gone = Gone

type stream = {
  produce : (string -> (unit, gone) result) -> (unit, gone) result;
  keep_alive : (float * string) option;
  length : int option;
}

type connection = Spindle_http.Connection.t = {
  reader : Eio.Buf_read.t;
  writer : Eio.Buf_write.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  send_timeout_s : float;
  stopping : unit Eio.Promise.t;
}

type content =
  | Buffered of string
  | Stream of stream
  | Takeover of { protocol : string; handle : connection -> unit }

(* The content type and cookies are fields, not headers: the framework
   writes them, and a handler's own would be a second answer. *)
type t = {
  status : Status.t;
  content_type : string option;
  headers : (string * string) list;
  cookies : Cookie.t list;
  content : content;
  refused : Refusal.t option;
  closing : bool;
}

let make ?(status = `OK) ?(headers = []) ?(cookies = [])
    ?(content_type = "text/plain; charset=utf-8") body =
  {
    status;
    content_type = Some content_type;
    headers;
    cookies;
    content = Buffered body;
    refused = None;
    closing = false;
  }

(* The API document describes a refusal from this description. *)
let problem_json =
  Wiretype.Object.map ~kind:"problem"
    ~doc:"One input that is not what it should be." (fun at code message ->
      { Refusal.at; code; message })
  |> Wiretype.Object.mem "at" Wiretype.string
       ~doc:"Where: path.x, query.x, body.x." ~enc:(fun (p : Refusal.problem) ->
         p.at)
  |> Wiretype.Object.mem "code" Wiretype.string
       ~enc:(fun (p : Refusal.problem) -> p.code)
  |> Wiretype.Object.mem "message" Wiretype.string
       ~enc:(fun (p : Refusal.problem) -> p.message)
  |> Wiretype.Object.finish

let refusal_json =
  Wiretype.Object.map ~kind:"refusal"
    ~doc:
      "A refusal: the code a client branches on, and a sentence for a person."
    (fun code message problems -> (code, message, problems))
  |> Wiretype.Object.mem "error" Wiretype.string ~doc:"The code."
       ~enc:(fun (c, _, _) -> c)
  |> Wiretype.Object.mem "message" Wiretype.string ~doc:"A sentence."
       ~enc:(fun (_, m, _) -> m)
  |> Wiretype.Object.mem "problems"
       (Wiretype.list problem_json)
       ~doc:"For invalid: each input that is not what it should be." ~absent:[]
       ~omit:(function [] -> true | _ :: _ -> false)
       ~enc:(fun (_, _, p) -> p)
  |> Wiretype.Object.finish

(* Unreachable: strings always encode. A fallback rather than a raise,
   since nothing in this library raises. *)
let refusal (r : Refusal.t) =
  let answer =
    make ~status:(Refusal.status r) ~headers:r.headers
      ~content_type:"application/json"
      (Result.value
         (Wiretype.encode refusal_json
            (Refusal.Code.name r.code, r.message, r.problems))
         ~default:{|{"error":"internal"}|})
  in
  { answer with refused = Some r }

let json ?status ?headers ?cookies t v =
  match Wiretype.encode t v with
  | Ok body ->
      make ?status ?headers ?cookies ~content_type:"application/json" body
  | Error e ->
      refusal (Refusal.internal ~detail:(Wiretype.Unwritable.to_string e))

let html ?status ?headers ?cookies page =
  make ?status ?headers ?cookies ~content_type:"text/html; charset=utf-8" page

let empty ?(status = `No_content) ?(headers = []) ?(cookies = []) () =
  {
    status;
    content_type = None;
    headers;
    cookies;
    content = Buffered "";
    refused = None;
    closing = false;
  }

let redirect ?(status = `Found) ?cookies location =
  empty ~status ~headers:[ ("location", location) ] ?cookies ()

let stream ?(status = `OK) ?(headers = []) ?(cookies = [])
    ?(content_type = "application/octet-stream") ?length produce =
  {
    (make ~status ~headers ~cookies ~content_type "") with
    content = Stream { produce; keep_alive = None; length };
  }

let takeover ~protocol ?(headers = []) ?(cookies = []) handle =
  {
    (empty ~status:`Switching_protocols ~headers ~cookies ()) with
    content = Takeover { protocol; handle };
  }

(* A cache or a buffering proxy holding events back defeats them, and nginx
   buffers unless told [x-accel-buffering: no]. *)
let events ?headers ?(keep_alive_s = 15.) produce =
  let r =
    stream ~content_type:"text/event-stream"
      ~headers:
        ([ ("cache-control", "no-cache"); ("x-accel-buffering", "no") ]
        @ Option.value headers ~default:[])
      produce
  in
  {
    r with
    content =
      Stream
        {
          produce;
          keep_alive = Some (keep_alive_s, ": keep-alive\n\n");
          length = None;
        };
  }

let status t = t.status
let content t = t.content
let content_type t = t.content_type
let headers t = t.headers
let cookies t = t.cookies
let refused t = t.refused
let add_headers extra t = { t with headers = t.headers @ extra }
let add_cookies extra t = { t with cookies = t.cookies @ extra }
let close_connection t = { t with closing = true }
let closes_connection t = t.closing
