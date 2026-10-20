(** How Spindle's server and client read and write the wire: a head read off a
    connection, where a body ends, a message written, and a WebSocket run over a
    connection. They are reached here because both ends are built on them, and
    are not covered by the library's version -- any may change in any release.
    An application names none of them. *)

module Head = Head
module Framing = Framing
module Write = Write
module Websocket = Websocket.Private
