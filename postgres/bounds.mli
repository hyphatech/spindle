(** The framework's bounds on a connection: what {!Spindle_postgres.connect} and
    {!Pool.create} both ask for. *)

val apply :
  ?statement_timeout:Mtime.Span.t ->
  ?idle_in_transaction_timeout:Mtime.Span.t ->
  ?connect_timeout:Mtime.Span.t ->
  ?parameters:(string * string) list ->
  string ->
  ( Rowtype_postgres.Conninfo.t * (string * string) list,
    [> Rowtype.error ] )
  result
(** The connection string read, with a connect timeout unless it names one, and
    the start-up parameters: the bounds, in whole milliseconds rounded up, and
    [DateStyle=ISO], then the application's own, which win over the framework's
    where they name one. *)
