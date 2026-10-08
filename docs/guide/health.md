# Health checks

`Spindle.Health.routes` adds the two routes an orchestrator or a load
balancer probes:

- **`GET /livez`** runs no check: it answers `ok` while the process can
  answer at all. A database outage should not get every instance restarted.
- **`GET /readyz`** runs every check, side by side, and answers `ok`, or
  `503 not_ready` naming the checks that failed. Point a platform that
  probes only one path here.

```ocaml
Spindle.serve env
  (routes @ Spindle.Health.routes [ Spindle_postgres.Pool.check pool ])
```

`Pool.check` borrows a connection and runs `select 1`. A pool whose
connections are all busy passes without waiting.

## Custom checks

A check is `Spindle.Health.check name f`, where `f ()` answers `Ok ()` or
`Error why`. This server is taken out of service while a file named
`maintenance` exists:

```ocaml
--8<-- "health.ml"
```

```sh
curl localhost:8080/readyz
```

```text
ok
```

```sh
touch maintenance
```

```sh
curl -i localhost:8080/readyz
```

```text
HTTP/1.1 503 Service Unavailable
content-type: application/json

{"error":"not_ready","message":"Not ready: maintenance."}
```

```sh
curl localhost:8080/livez
```

```text
ok
```

The answer names only the check; `why` goes to the log, as a `warn` line:
`not ready: maintenance: the maintenance file is there`.

Good to know:

- The framework sets no timeout on a check. A check that waits on something
  bounds its own wait (the pool has its borrow wait and statement timeout),
  and the prober sets how long it waits.
- A stopping server refuses new connections, so probes fail without any
  check.
- Probes are logged at `debug`, since something asks every few seconds.
- `~live` and `~ready` move the routes to other paths.
