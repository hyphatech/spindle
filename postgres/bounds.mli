(** The framework's bounds on a connection: what {!Spindle_postgres.connect} and
    {!Pool.create} both ask for. *)

val apply :
  ?statement_timeout:Mtime.Span.t ->
  ?idle_in_transaction_timeout:Mtime.Span.t ->
  ?parameters:(string * string) list ->
  Rowtype_postgres.Conninfo.t ->
  Rowtype_postgres.Conninfo.t * (string * string) list
(** The target, bounding its connect by ten seconds unless it names a bound of
    its own, and the start-up parameters: the bounds, in whole milliseconds
    rounded up, then the application's own, which win over the framework's where
    they name one. *)
