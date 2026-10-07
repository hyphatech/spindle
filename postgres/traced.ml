let observer =
  {
    Rowtype_postgres.around =
      (fun sql run ->
        Spindle.Trace.span ~kind:Spindle.Trace.Client
          ~attributes:
            [
              ("db.system.name", `String "postgresql");
              ("db.query.text", `String sql);
            ]
          "postgresql" run);
  }
