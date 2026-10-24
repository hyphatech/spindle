module Value = Wiretype.Value

let version = "2026-07-28"

type id = Int of int | String of string

let id_to_value = function
  | Int n -> Value.Number (float_of_int n)
  | String s -> Value.String s

type message =
  | Request of { id : id; meth : string; params : Value.t option }
  | Notification of { meth : string; params : Value.t option }

type error = Parse_error | Invalid_request of string

let ( let* ) = Result.bind
let invalid why = Error (Invalid_request why)

(* The largest integer a double holds exactly, 2^53: an id past it would not
   be the one sent. *)
let exact_integers = 9007199254740992.

(* JSON-RPC 2.0 §4 and MCP's basic §Messages: an id is a string or an
   integer, never null, which MCP refuses though JSON-RPC allows it. *)
let id_of = function
  | Value.String s -> Ok (String s)
  | Value.Number f when Float.is_integer f && Float.abs f < exact_integers ->
      Ok (Int (int_of_float f))
  | Value.Null -> invalid "a null id"
  | _ -> invalid "an id that is no string or integer"

let read text =
  match Wiretype.decode Value.json text with
  | Error _ -> Error Parse_error
  | Ok (Value.Array _) -> invalid "a batch, which MCP has none of"
  | Ok (Value.Object members) -> (
      let find name = List.assoc_opt name members in
      let* () =
        match find "jsonrpc" with
        | Some (Value.String "2.0") -> Ok ()
        | _ -> invalid "no \"jsonrpc\": \"2.0\""
      in
      let* () =
        match (find "result", find "error") with
        | None, None -> Ok ()
        | _ -> invalid "a response, which a client never sends"
      in
      let* meth =
        match find "method" with
        | Some (Value.String m) -> Ok m
        | _ -> invalid "no method"
      in
      let* params =
        match find "params" with
        | None -> Ok None
        | Some (Value.Object _ as p) -> Ok (Some p)
        | Some _ -> invalid "params that are no object"
      in
      match find "id" with
      | None -> Ok (Notification { meth; params })
      | Some v ->
          let* id = id_of v in
          Ok (Request { id; meth; params }))
  | Ok _ -> invalid "no object"

let member name = function
  | Some (Value.Object members) -> List.assoc_opt name members
  | _ -> None

let written members =
  match Wiretype.encode Value.json (Value.Object members) with
  | Ok text -> text
  (* Every value written here is made of strings, whole numbers and objects,
     which encode; this is the one answer left if one did not. *)
  | Error _ ->
      {|{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"}}|}

let result id members =
  written
    [
      ("jsonrpc", Value.String "2.0");
      ("id", id_to_value id);
      ("result", Value.Object members);
    ]

let notification meth params =
  written
    [
      ("jsonrpc", Value.String "2.0");
      ("method", Value.String meth);
      ("params", Value.Object params);
    ]

module Code = struct
  let parse_error = -32700
  let invalid_request = -32600
  let method_not_found = -32601
  let invalid_params = -32602
  let internal_error = -32603
  let header_mismatch = -32020
  let missing_capability = -32021
  let unsupported_version = -32022
end

let error ?id ?data code message =
  written
    ([ ("jsonrpc", Value.String "2.0") ]
    @ (match id with Some id -> [ ("id", id_to_value id) ] | None -> [])
    @ [
        ( "error",
          Value.Object
            ([
               ("code", Value.Number (float_of_int code));
               ("message", Value.String message);
             ]
            @ match data with Some d -> [ ("data", d) ] | None -> []) );
      ])
