let observer =
  {
    Rowtype_sqlite.around =
      (fun sql run ->
        Spindle.Trace.span ~kind:Spindle.Trace.Client
          ~attributes:
            [
              ("db.system.name", `String "sqlite");
              ("db.query.text", `String sql);
            ]
          "sqlite" run);
  }
