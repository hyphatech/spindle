(* The framework's bounds on a connection, as start-up parameters, so a
   connection made again keeps them. *)

module Pg = Rowtype_postgres

let apply ?(statement_timeout_ms = 10_000)
    ?(idle_in_transaction_timeout_ms = 30_000) ?(connect_timeout_s = 10)
    ?(parameters = []) target =
  Result.map
    (fun (c : Pg.Conninfo.t) ->
      (* DateStyle because an instant is read as the server writes it; the
         timeouts so the server ends a hung statement or a forgotten
         transaction rather than leaving it holding a pooled connection and
         its locks. The application's parameters win. *)
      let framework =
        [
          ("statement_timeout", string_of_int statement_timeout_ms);
          ( "idle_in_transaction_session_timeout",
            string_of_int idle_in_transaction_timeout_ms );
          ("DateStyle", "ISO");
        ]
      in
      ( {
          c with
          connect_timeout_s =
            Some
              (Option.value c.connect_timeout_s
                 ~default:(float_of_int connect_timeout_s));
        },
        List.filter (fun (k, _) -> not (List.mem_assoc k parameters)) framework
        @ parameters ))
    (Pg.conninfo target)
