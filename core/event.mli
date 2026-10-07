(** Server-Sent Events, declared: what a stream may send, by name and
    description, and each event made from its declaration.

    {[
    type room

    let state : (state, room) Event.kind = Event.json "state" state_json
    let token : (string, room) Event.kind = Event.text "token"

    Spindle.get
      path
      (Returns.events Event.[ declare state; declare token ])
      (let+ room = Spindle.param room in
       Ok (fun send -> ...))
    ]}

    A stream's events are a type of its own -- [room] here, declared and never
    defined -- which every kind declared for it carries, so an event of a kind
    made for another stream is refused by the compiler. An event is encoded
    once, when it is made, so the same value can be sent to every subscriber of
    a {!Broadcast} without being written again. *)

type ('a, 's) kind
(** An event stream ['s] may send: its name, and what its data is. *)

val json : string -> 'a Wiretype.t -> ('a, 's) kind
(** An event whose data is JSON, encoded by its description. *)

val text : string -> (string, 's) kind
(** An event whose data is text, sent as it is: a token of a model's answer, a
    line of a log. *)

val kind_name : ('a, 's) kind -> string

(** What an event's data is, for whatever describes the stream. *)
type 'a data = Json : 'a Wiretype.t -> 'a data | Text : string data

val kind_data : ('a, 's) kind -> 'a data

type 's declared = Declared : ('a, 's) kind -> 's declared

val declare : ('a, 's) kind -> 's declared
val declared_name : 's declared -> string

type !'s t
(** One event of stream ['s], already spelled. *)

val make : ?id:string -> ('a, 's) kind -> 'a -> 's t
(** The event, its data encoded by its kind. [id] is what a browser keeps and
    sends back as [Last-Event-ID] when it reconnects, so a stream that is asked
    for one can carry on after it. A value its own description cannot encode, an
    [id] holding a line break or a NUL, which no client could read back, or a
    kind whose name holds a line break, which would end its field early, is our
    bug: logged as an error where it is made, and the event sends nothing. *)

val retry : int -> 's t
(** [retry: ms]: how long a browser waits before it reconnects. A negative one,
    which a browser ignores, is our bug: logged, and it sends nothing. *)

val comment : string -> 's t
(** A comment, which every client ignores. The framework sends one on a stream
    that has been quiet for a while ({!Returns.events}), so nothing in between
    closes it as idle. *)

val name : 's t -> string option
(** The kind it was made from; [None] for {!retry} and {!comment}, which any
    stream may send. *)

val to_string : 's t -> string
(** As it goes on the wire, framing and all; nothing for an event that could not
    be made. *)

type gone = Response.gone = Gone

type 's stream = ('s t -> (unit, gone) result) -> (unit, gone) result
(** What an events route answers: given [send], it sends until it returns.
    [send] answers [Error Gone] once the client has gone, so a loop written with
    [let*] ends there. A producer waiting for something to send when its client
    goes learns it at its next [send]: nothing cancels it. *)
