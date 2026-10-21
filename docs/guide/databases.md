# Databases

`spindle-sqlite` and `spindle-postgres` wire a database into a server: a
pool, a readiness check, metrics, sessions, and the refusal a failure
answers. Both have the same calls, under `Spindle_sqlite` and
`Spindle_postgres`. The [Database](../tutorial/database.md) tutorial walks
through them on SQLite.

## Running statements

The routes read the pool through a resource, made once:

```ocaml
let db : Spindle_sqlite.Pool.t Spindle.Dep.t = Spindle.Dep.of_resource "database"
```

| Call | Runs |
|---|---|
| `Pool.exec pool statement params` | one statement on a borrowed connection |
| `Pool.transaction pool (fun db -> ...)` | one transaction: `Ok` commits, `Error` rolls back |
| `Pool.use pool (fun db -> ...)` | several statements on one connection, outside a transaction |

Inside `transaction` and `use`, a statement is `Rowtype_sqlite.run db
statement params`, or `Rowtype_postgres.run` on Postgres. `refusal` turns a
failure into an answer: a busy or closed pool and a lock held past its
wait are `503`, anything else `500`.

## SQLite

### Install

```sh
opam install spindle-sqlite rowtype-migrate
```

```lisp
(libraries spindle spindle-sqlite rowtype rowtype-sqlite eio_main)
```

### The pool

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Spindle_sqlite.Pool.run env "app.db" @@ fun pool ->
  Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
```

`Pool.run` opens every connection before the server listens, and puts the
file in WAL mode, so a read never waits on a write. SQLite keeps
`app.db-wal` and `app.db-shm` beside the file while it is open. A file that
cannot be opened stops the program, saying why. `Pool.create ~sw
~mono_clock file` answers a `result` instead.

| Option | Default | |
|---|---|---|
| `~size` | 8 | connections, all opened at start-up |
| `~wait` | 5 s | a borrow waiting longer is `` `Pool `Busy ``, a `503` |
| `~timeout` | 5 s | a statement waiting longer for another's write lock is `` `Not_serializable ``, a `503` |

The durations are `Mtime.Span.t`s, written `Mtime.Span.(2 * s)`. A pool in
memory, `":memory:"`, is refused, since each connection would have a
database of its own.

### Transactions

`Pool.transaction` takes `~behaviour`, when it takes the write lock:

- `Deferred`, the default, at its first write.
- `Immediate`, as it begins, for a transaction that reads and then writes.
- `Exclusive`, as it begins, keeping readers out too outside WAL mode.

`~retries:3` runs the whole transaction again when it meets
`` `Not_serializable ``, so keep anything that is not a statement out of the
work. `~keep` commits an `Error` it names. A unique key refused is a
`` `Conflict `` naming its columns, `users.email`.

### Migrations

```sh
rowtype-migrate create --url sqlite:app.db   # once, makes the file
rowtype-migrate up --url sqlite:app.db       # before each start
rowtype-migrate status --url sqlite:app.db --check
rowtype-migrate dump --url sqlite:app.db     # the schema the migrations make
```

### Sessions

`Spindle_sqlite.Session.store db` keeps [sessions](cookies.md#sessions) in
the table `spindle_sessions`, made by the migration the package ships:

```sh
rowtype-migrate up --source spindle-sqlite --url sqlite:app.db
```

`Session.store ~table db` reads a table of your own, made by a migration of
yours from `Session.schema ~table`.

## Postgres

### Install

```sh
opam install spindle-postgres rowtype-migrate
```

```lisp
(libraries spindle spindle-postgres rowtype rowtype-postgres eio_main)
```

To try it, a throwaway Postgres in Docker, deleted when it stops:

```sh
docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
```

### The pool

`Pool.run` takes a connection string, a `postgres://` URL or a keyword
list:

```ocaml
--8<-- "sql_postgres.ml:pool"
```

```console
$ dune exec examples/sql_postgres.exe
$ curl localhost:8080/
["postgres","template0","template1"]
```

??? example "The whole app"

    ```ocaml
    --8<-- "sql_postgres.ml"
    ```

`Pool.run` opens every connection before the server listens. A database
that cannot be reached stops the program, saying why. `Pool.create ~sw ~net
~mono_clock target` answers a `result` instead, its `target` read by
`Rowtype_postgres.Conninfo.of_string`.

Every connection is bounded, so one bad query cannot hold a connection and
its locks for ever:

| Option | Default | |
|---|---|---|
| `~statement_timeout` | 10 s | a statement running longer is ended by Postgres |
| `~idle_in_transaction_timeout` | 30 s | so is a transaction left open and idle |
| `~size` | 8 | connections, all opened at start-up |
| `~wait` | 5 s | a borrow waiting longer is `` `Pool `Busy ``, a `503` |
| `~parameters` | none | settings for each connection, `[ ("application_name", "shop") ]`, which win over the framework's |
| `~statement_cache` | the driver's | `0` behind a pooler that cannot carry named statements |

Connecting waits 10 s for each address unless the connection string says
`connect_timeout`. The two bounds reach Postgres in whole milliseconds,
rounded up, and a span of zero lifts one.

### Transactions

`Pool.transaction` takes `~isolation`. At `~isolation:Serializable`,
`~retries:3` runs the transaction again when Postgres reports a conflict
with a concurrent one. A unique key refused is a `` `Conflict `` naming the
constraint, `users_email_key`, whether a statement found it or a
`DEFERRABLE` constraint refused the `COMMIT`. `refusal` answers
`` `Unsent ``, a database not reached, with a `503` too.

### Migrations

```sh
rowtype-migrate create --url postgres://app@db/shop   # once
rowtype-migrate up --url postgres://app@db/shop       # before each start
```

### Sessions

`Spindle_postgres.Session.store db` keeps [sessions](cookies.md#sessions) in
the table `spindle_sessions`, made by the migration the package ships:

```sh
rowtype-migrate up --source spindle-postgres --url postgres://app@db/shop
```

## Health and metrics

```ocaml
Spindle.Health.routes [ Spindle_sqlite.Pool.check db ]
Spindle_sqlite.Pool.measure pool metrics
```

`check` borrows a connection and runs `select 1`, and passes without one
while every connection is lent. `measure` reports the pool's connections,
named `sqlite` or `postgres` unless given `~name` ([Health
checks](health.md), [Metrics](metrics.md)).
