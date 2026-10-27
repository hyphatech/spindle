(* A request's body while a route runs: read whole once and kept for every
   dependency, or handed to the one that streams it. *)

type error = Request_repr.body_error

module L = (val Logs.src_log Log.http : Logs.LOG)

type source = {
  whole :
    ?max_body:int ->
    ?body_timeout:Mtime.Span.t ->
    ?min_body_rate:int ->
    unit ->
    (string, error) result;
  part :
    ?max_body:int ->
    ?body_timeout:Mtime.Span.t ->
    ?min_body_rate:int ->
    unit ->
    ([ `Data of string | `End ], error) result;
}

exception Unholdable of { max_body : int; body_budget : int }

type held = {
  source : source;
  pattern : string;  (** the route's, for the log *)
  limits : Limits_repr.route;
  mutable read : (string, error) result option;
  mutable streamed : bool;
  mutable handler_returned : bool;
}

type t = { held : held; mutable failed : error option; mutable ended : bool }

let hold source ~pattern ~limits =
  {
    source;
    pattern;
    limits;
    read = None;
    streamed = false;
    handler_returned = false;
  }

let refusal : error -> Refusal.t = function
  | Request_repr.Too_large -> Refusal.too_large
  | Request_repr.Over_budget -> Refusal.busy ()
  | Request_repr.Unreadable detail -> Refusal.unreadable ~detail

(* A multipart body cut wrong, read as a form or a part at a time: one
   answer, at [body], the detail for the log. *)
let not_multipart ~detail =
  Refusal.make ~detail
    ~problems:
      [
        {
          Refusal.at = "body";
          code = "malformed";
          message = "This is not a multipart form.";
        };
      ]
    Refusal.Code.invalid "Some of that request is not what it should be."

(* Once, however many dependencies ask. A stream already begun leaves nothing
   whole; [App.make] refuses that, unless a [bind] hides it. *)
let whole h =
  match h.read with
  | Some r -> r
  | None ->
      let r =
        if h.streamed then
          Error
            (Request_repr.Unreadable
               (h.pattern ^ " read its body whole after reading it as a stream"))
        else
          let l = h.limits in
          match
            h.source.whole ?max_body:l.max_body ?body_timeout:l.body_timeout
              ?min_body_rate:l.min_body_rate ()
          with
          | r -> r
          | exception (Unholdable { max_body; body_budget } as e) ->
              L.err (fun m ->
                  m
                    "%s reads its body whole with max_body %d, above \
                     body_budget %d: no body above the budget can be held"
                    h.pattern max_body body_budget);
              raise e
      in
      h.read <- Some r;
      r

let stream h =
  h.streamed <- true;
  { held = h; failed = None; ended = false }

let part h =
  let l = h.limits in
  h.source.part ?max_body:l.max_body ?body_timeout:l.body_timeout
    ?min_body_rate:l.min_body_rate ()

let end_handler h = h.handler_returned <- true
