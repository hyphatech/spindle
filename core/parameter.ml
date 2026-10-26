module S = Wiretype.Schema

(* A scalar makes no component, so its walk needs no context of the
   document's. *)
let schema d = S.walk (S.create ()) S.Decode ~at:"a parameter" d

let kind (type a) (d : a Wiretype.t) =
  match d with
  | Wiretype.Shape.Enum (about, _) | Wiretype.Shape.Map (about, _) ->
      if String.equal about.kind "" then None else Some about.kind
  | _ -> None

let rec scalar = function
  | S.String _ | S.Number _ | S.Integer _ | S.Boolean -> true
  | S.Described { schema; _ } -> scalar schema
  | _ -> false

let default ~at d v =
  match Wiretype.to_value d v with
  | Ok value -> value
  | Error (u : Wiretype.Unwritable.t) ->
      invalid_arg
        (Printf.sprintf "%s's default cannot be written: %s" at u.message)
