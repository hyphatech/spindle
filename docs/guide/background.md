# Work nobody is waiting for

- `Spindle.Background.create ~sw`, once at startup, and
  `Spindle.Background.fork t ~what f` from anywhere -- a daemon fibre whose
  exception is **logged, never raised**, because a raise would fail the
  server's own switch and every request with it. It inherits the forking
  request's id. It runs on the domain that forked it, on that domain's own
  switch; from a domain Spindle does not run -- an `Executor_pool` worker of
  the application's -- it is posted to the fiber `create` started on `sw`.
- `Spindle.Alarm.set t ~key ~in_ms ~what f` -- "look at this again later", one
  per key, from any domain; setting a key again cancels the earlier wake-up's
  fibre wherever it sleeps, and a key is forgotten once it fires or is
  cancelled, so the table holds only what is still to come. A wake-up is a
  fork of the `Background` that `Alarm.create` is given, on the domain that
  set it, and sleeps on the monotonic clock it is given, so a wall clock that
  jumps moves nothing. The alarm decides *when* to look, never what the time
  is.
