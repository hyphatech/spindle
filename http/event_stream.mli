(** Server-Sent Events, as the HTML standard writes and reads an event stream
    ([text/event-stream]): what a server sends and what a client reads it as, in
    one module, so both ends of a stream have one account of where an event
    ends.

    {[
    Event_stream.event ~name:"state" ~id:"7" {|{"n":1}|}
    = Ok "event: state\nid: 7\ndata: {\"n\":1}\n\n"

    let r = Event_stream.reader () in
    Event_stream.feed r "event: state\ndata: a\n\ndata: b"
    = Ok [ { name = "state"; data = "a"; id = None; retry = None } ]
    ]} *)

(** {1 Writing} *)

val event : ?name:string -> ?id:string -> string -> (string, string) result
(** An event as it goes on the wire: its name, its id and its data, a line break
    in the data written as another [data:] line, which a reader joins back with
    the break. [Error] names, for a log, what no reader could read back: a name
    holding a line break, which would end its field early, or an id holding a
    line break or a NUL, which a browser ignores. *)

val retry : int -> (string, string) result
(** [retry: ms]: how long a client waits before it reconnects; [Error] for a
    negative one, which a browser ignores. *)

val comment : string -> string
(** A comment, which every reader passes over: what keeps a quiet stream from
    being closed as idle. *)

(** {1 Reading} *)

type event = {
  name : string;  (** [message] where the stream named none *)
  data : string;  (** its [data:] lines, joined by line breaks *)
  id : string option;
      (** the last id the stream set, at the event: what a reconnecting client
          sends back as [Last-Event-ID] *)
  retry : int option;  (** the reconnection time the stream last set, in ms *)
}

type reader
(** One stream being read, a piece at a time: a line may be cut anywhere. *)

val reader : ?last_id:string -> ?max_event:int -> unit -> reader
(** [last_id] is the id a reconnection carried on from. [max_event] (1 MiB)
    bounds what the reader holds between events: the line not yet ended and the
    data not yet dispatched. *)

val feed : reader -> string -> (event list, string) result
(** The events this piece completed, in order, or [Error] once what the reader
    holds between events passes [max_event], which a stream that never ends a
    line otherwise grows without end. A line ends at CRLF, LF or a lone CR, a
    blank line dispatches, a line beginning with a colon is a comment, and a
    field is [event], [data], [id] -- one holding a NUL ignored -- or [retry],
    digits only; any other is passed over. An event with no data is not
    dispatched, though its id is kept. A leading byte-order mark is passed over;
    the rest is the bytes as they came, the reader's to decode. *)

val last_id : reader -> string option
(** The id a reconnection should carry on from: the last one an event was
    dispatched with. *)
