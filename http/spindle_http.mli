(** HTTP as both ends speak it: what a server and a client share, and what an
    application names -- statuses, methods, fields and the values they carry,
    the messages spoken after HTTP, and what a line is logged with. Each
    module's [.mli] is its reference. *)

(** {1 Messages} *)

module Status = Status
module Meth = Meth
module Version = Version
module Field = Field

(** {1 Values a field carries} *)

module Media_type = Media_type
module Accept = Accept
module Auth = Auth
module Cache_control = Cache_control
module Date = Date
module Etag = Etag
module Range = Range
module Forwarded = Forwarded
module Structured = Structured

(** {1 Bodies} *)

module Urlencoded = Urlencoded
module Multipart = Multipart
module Event_stream = Event_stream

(** {1 After HTTP} *)

module Connection = Connection

module Websocket : module type of struct
  include Websocket
end
with module Private := Websocket.Private

(** {1 Running} *)

module Instant = Instant
module Log = Log
module Trace = Trace
module Local = Local

(** {1 Spindle's own} *)

module Private = Private
