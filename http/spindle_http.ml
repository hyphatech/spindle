module Status = Status
module Meth = Meth
module Version = Version
module Field = Field
module Media_type = Media_type
module Accept = Accept
module Auth = Auth
module Cache_control = Cache_control
module Date = Date
module Etag = Etag
module Range = Range
module Forwarded = Forwarded
module Structured = Structured
module Urlencoded = Urlencoded
module Multipart = Multipart
module Event_stream = Event_stream
module Connection = Connection

module Websocket : module type of struct
  include Websocket
end
with module Private := Websocket.Private =
  Websocket

module Instant = Instant
module Log = Log
module Trace = Trace
module Local = Local
module Private = Private
