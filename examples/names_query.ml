(* The statement sql_query runs, and the handler that runs it on a pool. *)

module S = Rowtype

let claimed =
  S.list ~params:S.unit ~row:S.text "select name from names order by name"

(* A borrow that waits past the pool's limit is [`Pool `Busy], which [refusal]
   answers 503: an overloaded server says so rather than answering late. *)
let list_names pool =
  Spindle_sqlite.Pool.exec pool claimed ()
  |> Result.map_error Spindle_sqlite.refusal
