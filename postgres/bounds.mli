(** The framework's bounds on a connection: what {!Spindle_postgres.connect} and
    {!Pool.create} both ask for. *)

val apply :
  ?statement_timeout_ms:int ->
  ?idle_in_transaction_timeout_ms:int ->
  ?connect_timeout_s:int ->
  ?parameters:(string * string) list ->
  string ->
  ( Rowtype_postgres.Conninfo.t * (string * string) list,
    [> Rowtype.error ] )
  result
(** The connection string read, with a connect timeout unless it names one, and
    the start-up parameters: the bounds and [DateStyle=ISO], then the
    application's own, which win over the framework's where they name one. *)
