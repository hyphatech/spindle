module L = (val Logs.src_log Log.http : Logs.LOG)

type t = Body_repr.t
type error = Request_repr.body_error = Too_large | Unreadable of string | Busy

type source = Body_repr.source = {
  whole : unit -> (string, error) result;
  part : max:int -> ([ `Data of string | `End ], error) result;
}

let read (t : t) =
  if t.held.handler_returned then (
    L.warn (fun m ->
        m "%s read its body after its answer had gone, which read nothing"
          t.held.pattern);
    Ok `End)
  else
    match (t.failed, t.ended) with
    | Some e, _ -> Error e
    | None, true -> Ok `End
    | None, false -> (
        match t.held.source.part ~max:t.max with
        | Ok `End ->
            t.ended <- true;
            Ok `End
        | Ok (`Data _) as data -> data
        | Error e ->
            t.failed <- Some e;
            Error e)

let refusal = Body_repr.refusal
