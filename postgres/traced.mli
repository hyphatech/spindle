(** What watches the statements of every connection the library makes. *)

val observer : Rowtype_postgres.observer
(** Each statement a {!Spindle.Trace.Client} span of the trace the fiber is in,
    named [postgresql], as OpenTelemetry names a statement it has no summary of,
    with its text as [db.query.text] and never its parameters; outside a kept
    trace, the statement alone. *)
