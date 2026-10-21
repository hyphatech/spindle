module Pool = Pool
module Session = Session

type error =
  [ Rowtype.error
  | Rowtype_sqlite.Transaction.failure
  | Rowtype_sqlite.Pool.error ]

let error_to_string : [< error ] -> string =
 fun e -> Rowtype_sqlite.error_to_string (e :> Rowtype_sqlite.error)

module L = (val Logs.src_log Source.src : Logs.LOG)

(* An unhandled conflict is a 500: a 409 the route never declared is a code
   it cannot answer. An exhausted pool is logged as a warning, not as the
   refusal's detail, which a 5xx logs as an error: a server under load is
   degraded, not broken. *)
let refusal : [< error ] -> Spindle.Refusal.t = function
  | `Pool `Busy ->
      L.warn (fun m -> m "busy: no database connection free within the wait");
      Spindle.Refusal.busy ()
  | `Pool `Closed ->
      L.warn (fun m -> m "the database pool is closed");
      Spindle.Refusal.busy ()
  | `Unsent detail ->
      L.warn (fun m -> m "the database could not be reached: %s" detail);
      Spindle.Refusal.busy ()
  | `Not_committed detail -> Spindle.Refusal.internal ~detail
  | `Not_serializable detail -> Spindle.Refusal.busy ~detail ()
  | #Rowtype.error as e ->
      Spindle.Refusal.internal ~detail:(Rowtype.error_to_string e)
