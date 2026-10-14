(* The framework's bounds on a connection, as start-up parameters, so a
   connection made again keeps them. *)

module Pg = Rowtype_postgres

(* Postgres reads a timeout in whole milliseconds, and 0 as none: rounded
   up, so a span under a millisecond is still a bound. *)
let milliseconds span =
  Int64.to_string
    (Int64.unsigned_div
       (Int64.add (Mtime.Span.to_uint64_ns span) 999_999L)
       1_000_000L)

(* Ten seconds to connect where the target names no bound of its own, as a
   server would rather say its database is unreachable than wait. *)
let connect_timeout = Mtime.Span.(10 * s)

let apply ?(statement_timeout = Mtime.Span.(10 * s))
    ?(idle_in_transaction_timeout = Mtime.Span.(30 * s)) ?(parameters = [])
    (c : Pg.Conninfo.t) =
  (* The timeouts so the server ends a hung statement or a forgotten
     transaction rather than leaving it holding a pooled connection and its
     locks. The application's parameters win. *)
  let framework =
    [
      ("statement_timeout", milliseconds statement_timeout);
      ( "idle_in_transaction_session_timeout",
        milliseconds idle_in_transaction_timeout );
    ]
  in
  ( (match c.connect_timeout with
    | Some _ -> c
    | None -> Pg.Conninfo.with_connect_timeout c connect_timeout),
    List.filter (fun (k, _) -> not (List.mem_assoc k parameters)) framework
    @ parameters )
