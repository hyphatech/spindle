(** A body read a part at a time, as it arrives: what {!Spindle.multipart} hands
    a route, for an upload too large to hold.

    {[
    let rec each parts =
      match Spindle.Multipart.next parts with
      | Ok None -> Ok receipt
      | Ok (Some part) ->
          let* () = save part parts in
          each parts
      | Error e -> Error (Spindle.Multipart.refusal e)
    ]}

    {b Every failure is a value}, as {!module-Body}'s are: a body that is no
    [multipart/form-data], a part's head past its limit, and the body's own --
    too large, no room, stopped arriving -- are each an [Error] from {!next} or
    {!read}. {b Where a part goes is the route's}: nothing is written to a
    temporary file, and a part left unread is passed over by the next {!next}.
*)

type t = Body.error Spindle_http.Multipart.t
(** The protocol's own reader, over the body's own failures. *)

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

type error =
  | Malformed of string  (** what was wrong, for the log *)
  | Head_too_large  (** a part's head past the route's [max_head] *)
  | Body of Body.error  (** the body's own failure *)

val next : t -> (part option, error) result
(** The next part's head; [None] after the last. *)

val read : t -> ([ `Data of string | `End ], error) result
(** The current part's bytes as they arrive, [`End] where it ends. *)

val refusal : error -> Refusal.t
(** A malformed body is {!Refusal.invalid} at [body], a head too large
    {!Refusal.too_large}, and the body's own failure {!Body.refusal}'s. *)
