(** A body read a part at a time, as it arrives: what {!Spindle.multipart} hands
    a route, for an upload too large to hold.

    {[
    let rec each parts =
      let* part = Spindle.Multipart.next parts in
      match part with
      | None -> Ok receipt
      | Some part ->
          let* () = save part parts in
          each parts
    ]}

    {b Every failure is the route's answer}, as {!module-Body}'s is: a body that
    is no [multipart/form-data] is {!Refusal.invalid} at [body], a part's head
    past its limit {!Refusal.too_large}, and the body's own failure its refusal
    -- each an [Error] from {!next} or {!read} that the handler's [let*] goes on
    through. {b Where a part goes is the route's}: nothing is written to a
    temporary file, and a part left unread is passed over by the next {!next}.
*)

type t = Refusal.t Spindle_http.Multipart.t
(** The protocol's own reader, over the body's own failures, already refusals.
*)

type part = Spindle_http.Multipart.part = {
  name : string;
  filename : string option;
      (** text a person chose, and never a path: a route that saves a file names
          it itself *)
  content_type : Spindle_http.Media_type.t;
      (** [text/plain] where it sent none, [application/octet-stream] where it
          sent one no reader can read *)
  headers : (string * string) list;
}

val next : t -> (part option, Refusal.t) result
(** The next part's head; [None] after the last. *)

val read : t -> ([ `Data of string | `End ], Refusal.t) result
(** The current part's bytes as they arrive, [`End] where it ends. *)
