module L = (val Logs.src_log Log.http : Logs.LOG)

type 'a data = Json : 'a Wiretype.t -> 'a data | Text : string data
type ('a, 's) kind = { name : string; data : 'a data }

let json name data = { name; data = Json data }
let text name = { name; data = Text }
let kind_name (k : _ kind) = k.name
let kind_data k = k.data

type 's declared = Declared : ('a, 's) kind -> 's declared

let declare k = Declared k
let declared_name (Declared k) = k.name

type 's t = { name : string option; wire : string }

let encode_data : type a. a data -> a -> (string, string) result =
 fun data v ->
  match data with
  | Json d ->
      Result.map_error Wiretype.Unwritable.to_string (Wiretype.encode d v)
  | Text -> Ok v

(* A value that cannot be encoded is our bug, logged here where the kind is
   known; the event sends nothing and the stream goes on. *)
let make ?id (k : _ kind) v =
  match
    Result.bind (encode_data k.data v)
      (Spindle_http.Event_stream.event ~name:k.name ?id)
  with
  | Ok wire -> { name = Some k.name; wire }
  | Error m ->
      L.err (fun f -> f "the event %s could not be made: %s" k.name m);
      { name = Some k.name; wire = "" }

let retry ms =
  match Spindle_http.Event_stream.retry ms with
  | Ok wire -> { name = None; wire }
  | Error m ->
      L.err (fun f -> f "%s" m);
      { name = None; wire = "" }

let comment s = { name = None; wire = Spindle_http.Event_stream.comment s }
let name (e : _ t) = e.name
let to_string e = e.wire

type gone = Response.gone = Gone
type 's stream = ('s t -> (unit, gone) result) -> (unit, gone) result
