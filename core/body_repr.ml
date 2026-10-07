(* A request's body while a route runs: read whole once and kept for every
   dependency, or handed to the one that streams it. *)

type error = Request_repr.body_error

type source = {
  whole : unit -> (string, error) result;
  part : max:int -> ([ `Data of string | `End ], error) result;
}

type held = {
  source : source;
  pattern : string;  (** the route's, for the log *)
  mutable read : (string, error) result option;
  mutable streamed : bool;
  mutable handler_returned : bool;
}

type t = {
  held : held;
  max : int;
  mutable failed : error option;
  mutable ended : bool;
}

let hold source ~pattern =
  { source; pattern; read = None; streamed = false; handler_returned = false }

let refusal : error -> Refusal.t = function
  | Request_repr.Too_large -> Refusal.too_large
  | Request_repr.Busy -> Refusal.busy ()
  | Request_repr.Unreadable detail -> Refusal.unreadable ~detail

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
        else h.source.whole ()
      in
      h.read <- Some r;
      r

let stream h ~max =
  h.streamed <- true;
  { held = h; max; failed = None; ended = false }

let end_handler h = h.handler_returned <- true
