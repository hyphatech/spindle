(** A request body read as it arrives: what {!Spindle.body_stream} hands a
    route, for a body too large to hold -- an upload.

    {[
    let rec save file body =
      match Spindle.Body.read body with
      | Ok (`Data part) ->
          Out_channel.output_string file part;
          save file body
      | Ok `End -> Ok ()
      | Error e -> Error (Spindle.Body.refusal e)
    ]}

    {b Every failure is a value.} A body past the route's limit, one the server
    has no room for, and one that stops arriving or breaks its framing are each
    an [Error] from {!read}, the route's to answer -- with {!refusal}, or a
    refusal of its own. Nothing is raised to the route and nothing it raises is
    caught.

    {b The body is the handler's while it runs.} A read after the handler has
    returned -- from a stream's producer, a fibre it left behind -- is [`End],
    and is logged as the route's bug: the connection is by then the loop's
    again. What the route left unread is discarded by the loop as any unread
    body is. *)

type t = Body_repr.t

(** Why a body could not be read. *)
type error = Request_repr.body_error =
  | Too_large  (** longer than the route's limit *)
  | Unreadable of string
      (** it stopped arriving, the connection failed, or it was not framed as it
          said *)
  | Busy  (** no room left in the server's budget for bodies being held *)

val read : t -> ([ `Data of string | `End ], error) result
(** The next part of the body as it arrived, at most 64 KiB, or its end. An
    error is the body's last word: every read after it answers the same. *)

val refusal : error -> Refusal.t
(** What the framework answers for a body it read whole and could not:
    {!Refusal.too_large}, {!Refusal.busy} or {!Refusal.unreadable}. *)

type source = Body_repr.source = {
  whole : unit -> (string, error) result;
      (** the whole body, within the server's own limit *)
  part : max:int -> ([ `Data of string | `End ], error) result;
      (** its next part, [Too_large] once the parts read pass [max] *)
}
(** How a connection loop hands a request's body over ({!App.handle}): read
    whole, or a part at a time, and never both. *)
