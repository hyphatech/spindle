module Pool = Pool
module Session = Session

type error = [ Rowtype.error | Rowtype_postgres.Transaction.failure | `Busy ]

let instant = Instant.ms

module L = (val Logs.src_log Source.src : Logs.LOG)

(* An unhandled conflict is a 500: a 409 the route never declared is a code
   it cannot answer. An exhausted pool is logged as a warning, not as the
   refusal's detail, which a 5xx logs as an error: a server under load is
   degraded, not broken. *)
let refusal : [< error ] -> Spindle.Refusal.t = function
  | `Busy ->
      L.warn (fun m -> m "busy: no database connection free within the wait");
      Spindle.Refusal.busy ()
  | `Not_committed detail -> Spindle.Refusal.internal ~detail
  | `Not_serializable detail -> Spindle.Refusal.busy ~detail ()
  | (`Conflict _ | `Db _ | `Closed | `Lost _) as e ->
      Spindle.Refusal.internal ~detail:(Rowtype.error_to_string e)

let connect ~sw ~net ~mono_clock:clock ?statement_timeout_ms
    ?idle_in_transaction_timeout_ms ?connect_timeout_s ?parameters ?timeout_s
    ?statement_cache target =
  Result.bind
    (Bounds.apply ?statement_timeout_ms ?idle_in_transaction_timeout_ms
       ?connect_timeout_s ?parameters target) (fun (c, parameters) ->
      Rowtype_postgres.connect ~sw ~net ~mono_clock:clock ~parameters
        ~observe:Traced.observer ?timeout_s ?statement_cache c)
