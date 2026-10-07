module Status = Spindle_http.Status
module Websocket = Spindle_http.Websocket
include Returns_repr

(* As [Status.of_int] makes it, so two spellings of one code compare equal. *)
let normalise_status status = Status.of_int (Status.to_int status)

let normalise_statuses statuses =
  List.map (fun (s, doc) -> (normalise_status s, doc)) statuses

let json ?(status = `OK) ?(examples = []) description : (_, Refusal.t) result t
    =
  Json { status = normalise_status status; description; examples }

let json_response ?(examples = []) ~statuses description :
    (_ * _, Refusal.t) result t =
  Json_response
    { statuses = normalise_statuses statuses; description; examples }

let html : (string, Refusal.t) result t = Html
let text : (string, Refusal.t) result t = Text

let empty ?(status = `No_content) () : (unit, Refusal.t) result t =
  Empty (normalise_status status)

let empty_response ~statuses : (Status.t, Refusal.t) result t =
  Empty_response (normalise_statuses statuses)

let response : (Response.t, Refusal.t) result t = Response

let events ?(keep_alive_s = 15.) declared : (_ Event.stream, Refusal.t) result t
    =
  Events { declared; keep_alive_s }

let websocket ?keep_alive_s ?max_message protocol :
    ((_, _) Websocket.t -> (unit, Websocket.error) result, Refusal.t) result t =
  Websocket { protocol; keep_alive_s; max_message }
