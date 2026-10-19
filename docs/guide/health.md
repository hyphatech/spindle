# Health checks

`Spindle.Health.routes` adds the two routes an orchestrator or a load
balancer probes:

- **`GET /livez`** runs no check: it answers `ok` while the process can
  answer at all. A database outage should not get every instance restarted.
- **`GET /readyz`** runs every check, side by side, and answers `ok`, or
  `503 not_ready` naming the checks that failed. Point a platform that
  probes only one path here.

```ocaml
let routes = app_routes @ Spindle.Health.routes [ Spindle_postgres.Pool.check db ]

let () =
  Eio_main.run @@ fun env ->
  Spindle_postgres.Pool.run env database @@ fun pool ->
  Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
```

`Pool.check db` reads the pool as your routes do, through the
[resource](../tutorial/dependencies.md#resources) `db`, so the probes are
routes like the rest, made before the pool is. It borrows a connection and
runs `select 1`. A pool whose
connections are all busy passes without waiting; a closed one fails.

## Custom checks

A check is `Spindle.Health.check name f`, where `f` is a
[dependency](../tutorial/dependencies.md) giving the function a probe runs,
which answers `Ok ()` or `Error why`. A check that reads nothing is
`Spindle.Dep.return (fun () -> ...)`; one that reads what the application
holds reads it as a route does:
`Spindle.Health.check "cache" (let+ cache = cache in fun () -> Cache.ping cache)`. Return `Error`, never raise: a check that raises is a bug, and
is answered `500`, not `503 not_ready`. This server is taken out of service while a file named
`maintenance` exists:

```ocaml
--8<-- "health.ml"
```

```console
$ curl localhost:8080/readyz
ok

$ touch maintenance

$ curl -i localhost:8080/readyz
HTTP/1.1 503 Service Unavailable
content-type: application/json
...

{"error":"not_ready","message":"Not ready: maintenance."}

$ curl localhost:8080/livez
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
- `~live` and `~ready` move the routes to other paths:
  `Spindle.Health.routes ~live:Spindle.Path.(s "healthz") checks`.
