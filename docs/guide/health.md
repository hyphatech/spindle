# Health probes

`Spindle.Health.routes` is the two questions an orchestrator, a load
balancer or a person asks of a running server, as routes added to the
application's own:

```ocaml
Spindle.serve env
  (routes @ Spindle.Health.routes [ Spindle_postgres.Pool.check pool ])
```

- **`GET /livez` runs no check.** It answers `ok` for as long as the
  process can answer, because what a failed liveness probe asks for is a
  restart, and a restart mends nothing a database's outage broke.
- **`GET /readyz` runs every check**, side by side, and answers `ok` or
  `503 not_ready`
  naming the checks that failed: `Not ready: postgres.` Why each failed is
  a `warn` line and nowhere else -- a database that is down is degraded, not
  our bug, which a 5xx refusal's detail would say at `error`. A platform
  that probes one path is pointed at this one.
- **A check is a value**: `Health.check name f`, where `f` answers `Ok ()`
  or `Error why`. A package offers its own -- `Pool.check` borrows a
  connection and asks `select 1`, and passes a pool with nothing idle
  without borrowing, since every connection is then lent to a request the
  database is answering.
- **How long to wait is the prober's to say**, as every prober does, and a
  check that waits on something bounds its own wait -- the pool's borrow and
  its statement timeout -- so the framework keeps no deadline of its own.
- **Stopping needs no check.** A server told to stop stops accepting, so a
  probe's next connection is refused, and every answer while it drains says
  `Connection: close`.
- **A probe is logged at `debug`** (`Meta.access`), since something asks
  every few seconds.

`~live` and `~ready` move them. This server is taken out of service by a
file named `maintenance`:

```ocaml
--8<-- "health.ml"
```
