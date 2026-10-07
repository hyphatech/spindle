(** Logging: one line per event, on stderr, through
    {{:https://erratique.ch/software/logs}logs}.

    Every library that logs through [logs] lands here too, so a line from TLS
    arrives beside a line from the application in the same shape. A line inside
    a request carries that request's id; a fiber the request forks inherits it,
    and {!carry} takes it onto a systhread -- so everything one request caused
    is one search.

    Levels mean one thing each: [Error] is our bug, [Warning] something handled
    but degraded, [Info] what happened -- the access log among it -- and [Debug]
    how. A secret has no level: the framework logs no header value and no body
    at all, and an application that logs one has chosen to. *)

include module type of struct
  include Spindle_http.Log
end

type format =
  | Pretty  (** for a terminal *)
  | Json  (** one object per line, for whatever collects them *)

val setup :
  ?format:format ->
  ?level:Logs.level option ->
  ?sources:(string * Logs.level option) list ->
  ?out:(string -> unit) ->
  unit ->
  unit
(** Installs the reporter. [level] is every source's, [Info] by default, and
    [sources] overrides it for the ones named -- except the sources that log
    what crossed the wire (TLS tracing), which [level] never raises past
    [Warning]: at [Debug] they are every header, credentials included. Only
    naming one in [sources] turns it up. [out] receives each line without its
    newline, under a lock, and is a test's way of keeping them; without it a
    line goes to stderr. Each domain gathers its lines in a buffer of its own,
    and a domain of the log's own, started by the first [setup] that needs it,
    writes every domain's at most once a millisecond, in one flush, so no domain
    waits on stderr and what is left is written before the process exits. A
    domain's lines keep their order, and lines from two domains are ordered by
    their timestamps. It turns on [Printexc.record_backtrace], which the domains
    started after it inherit, so {!raised} has a stack to give: call it before
    the server starts its domains. [format] defaults to [Pretty] when stderr is
    a terminal and [Json] when it is not. Safe from several threads and domains:
    a line is formatted on the one that logged it. *)

val configure :
  levels:string option -> format:string option -> (unit, string) result
(** {!setup} from two strings an application read from wherever it keeps its
    settings: [levels] is ["info"] or ["info,rowtype-postgres=debug"], and
    [format] is ["pretty"] or ["json"]. Either blank is the same as absent. The
    error names what could not be read. The framework reads no environment
    variable itself. *)
