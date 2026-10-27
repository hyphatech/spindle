(** A request body read as it arrives: what {!Spindle.body_stream} hands a
    route, for a body too large to hold -- an upload.

    {[
    let rec save file body =
      let* part = Spindle.Body.read body in
      match part with
      | `Data part ->
          Out_channel.output_string file part;
          save file body
      | `End -> Ok ()
    ]}

    {b Every failure is the route's answer.} A body past the route's limit is
    {!Refusal.too_large}, one the server has no room for {!Refusal.busy}, and
    one that stops arriving or breaks its framing {!Refusal.unreadable}: an
    [Error] from {!read} that the handler's [let*] goes on through, as a
    session's is ({!Session}). Its code tells one from another. Nothing is
    raised to the route and nothing it raises is caught.

    {b The body is the handler's while it runs.} A read after the handler has
    returned -- from a stream's producer, a fibre it left behind -- is [`End],
    and is logged as the route's bug: the connection is by then the loop's
    again. So is a read still waiting when the handler returns, stopped before
    the loop reads on. What the route left unread is discarded by the loop as
    any unread body is. *)

type t = Body_repr.t

(** Why a body could not be read, as a connection loop says it ({!source}). *)
type error = Request_repr.body_error =
  | Too_large  (** longer than the route's limit *)
  | Unreadable of string
      (** it stopped arriving, the connection failed, or it was not framed as it
          said *)
  | Over_budget
      (** no room left in the server's budget for bodies being held *)

val error_to_string : error -> string

val read : t -> ([ `Data of string | `End ], Refusal.t) result
(** The next part of the body as it arrived, at most 64 KiB, or its end. An
    error is the body's last word: every read after it answers the same. *)

type source = Body_repr.source = {
  whole :
    ?max_body:int ->
    ?body_timeout:Mtime.Span.t ->
    ?min_body_rate:int ->
    unit ->
    (string, error) result;
      (** the whole body, [Too_large] past [max_body] *)
  part :
    ?max_body:int ->
    ?body_timeout:Mtime.Span.t ->
    ?min_body_rate:int ->
    unit ->
    ([ `Data of string | `End ], error) result;
      (** its next part, [Too_large] once the parts read pass [max_body] *)
}
(** How a connection loop hands a request's body over ({!App.handle}): read
    whole, or a part at a time, and never both. Each limit is the route's where
    it gave one ({!Route.Limits}), and the loop's own where it is not given. *)
