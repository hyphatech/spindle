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

let apply ?(statement_timeout = Mtime.Span.(10 * s))
    ?(idle_in_transaction_timeout = Mtime.Span.(30 * s))
    ?(connect_timeout = Mtime.Span.(10 * s)) ?(parameters = []) target =
  Result.map
    (fun (c : Pg.Conninfo.t) ->
      (* DateStyle because an instant is read as the server writes it; the
         timeouts so the server ends a hung statement or a forgotten
         transaction rather than leaving it holding a pooled connection and
         its locks. The application's parameters win. *)
      let framework =
        [
          ("statement_timeout", milliseconds statement_timeout);
          ( "idle_in_transaction_session_timeout",
            milliseconds idle_in_transaction_timeout );
          ("DateStyle", "ISO");
        ]
      in
      ( Pg.Conninfo.with_connect_timeout c
          (Option.value c.connect_timeout ~default:connect_timeout),
        List.filter (fun (k, _) -> not (List.mem_assoc k parameters)) framework
        @ parameters ))
    (Pg.conninfo target)
