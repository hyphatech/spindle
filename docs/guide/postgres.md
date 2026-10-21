# Postgres

`spindle-postgres` is a server's Postgres: connections bounded as a server
bounds them, a pool and the probe that asks it, sessions in a table, and the
refusal a database failure answers. It is the
[Database](../tutorial/database.md) tutorial with `Spindle_postgres` in
place of `Spindle_sqlite`; this page is what differs, and its settings.

```sh
opam install spindle-postgres rowtype-migrate
```

```lisp
(executable
 (name main)
 (libraries spindle spindle-postgres rowtype rowtype-postgres eio_main)
 (preprocess (pps ppx_wiretype)))
```

Postgres is reached through a pure-OCaml driver, with nothing to link.

## When to choose Postgres

- **More than one machine.** Every instance of the server connects over the
  network, so they can run anywhere.
- **Many writers.** Writes to different rows go on side by side, and a
  transaction chooses its isolation.
- **A server to run.** Postgres is a server of its own, to start, secure,
  back up and upgrade, or a managed one to pay for.

To try it, start a throwaway Postgres in Docker. It listens on port 5432,
with the user and password `postgres`, and is deleted when you stop it:

```sh
docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
```

## The pool

`Spindle_postgres.Pool.run env target f` takes a connection string -- a
`postgres://` URL or a keyword list -- and opens every connection before the
server listens:

```ocaml
--8<-- "sql_postgres.ml:pool"
```

```console
$ dune exec examples/sql_postgres.exe
$ curl localhost:8080/
["postgres","template0","template1"]
```

If the database is not there, the program logs why and exits with status 1:

```
{"timestamp":"2026-10-16T09:24:46.621Z","level":"error","logger.name":"spindle-postgres","message":"the pool could not be opened: Eio.Io Net Connection_failure Refused Unix_error (Connection refused, \"connect\", \"\")"}
```

??? example "The whole app"

    ```ocaml
    --8<-- "sql_postgres.ml"
    ```

Every connection is bounded, so one bad query cannot hold a connection and
its locks for ever:

| Option | Default | |
|---|---|---|
| `~statement_timeout` | 10 s | a statement running longer is ended by Postgres |
| `~idle_in_transaction_timeout` | 30 s | so is a transaction left open and idle |
| `~size` | 8 | connections, all opened at start-up |
| `~wait` | 5 s | a borrow waiting longer is `` `Pool `Busy ``, a `503` |
| `~parameters` | none | Postgres settings for each connection, such as `[ ("application_name", "shop") ]`; yours win over the framework's |

`~size` is a count. The three durations are `Mtime.Span.t`s, written
`Mtime.Span.(2 * s)`. Connecting waits 10 s for each address unless the
connection string says `connect_timeout`
(`Conninfo.with_connect_timeout`). Postgres is given the two bounds in
whole milliseconds, rounded up, so a span under a millisecond is still a
bound; a span of zero lifts one, as Postgres's `0` does.

`Pool.create ~sw ~net ~mono_clock target` is the same pool answering a
`result`, for a program that can go on without its database; `target` is a
`Rowtype_postgres.Conninfo.t`, read from a connection string by
`Conninfo.of_string`. `~statement_cache:0` is for a pooler in front of
Postgres that cannot carry named statements.

## Transactions

`Pool.transaction pool (fun db -> ...)` takes `~isolation`, `~retries` and
`~keep`. A transaction is never run again unless you ask: at
`~isolation:Serializable`, pass `~retries:3` to run it again when Postgres
reports a conflict with a concurrent one (`` `Not_serializable ``). The work
runs again in full, so keep anything that is not a statement out of it.

A unique-constraint violation is a `` `Conflict `` named by its constraint,
`users_email_key`, whether a statement found it or a constraint declared
`DEFERRABLE` refused the transaction's `COMMIT`.

## Database errors

`Spindle_postgres.refusal` answers as `Spindle_sqlite.refusal` does
([Database errors](../tutorial/database.md#database-errors)), and one more:
`` `Unsent ``, the database could not be reached so nothing was done, is
`503 busy` too, logged as a warning, since asking again may succeed.
`` `Lost ``, a statement whose connection failed in flight, is `500`: what
the database did is not known.

## Migrations

The tables are `rowtype-migrate`'s, made before the server starts:

```sh
rowtype-migrate create --url postgres://app@db/shop   # once
rowtype-migrate up --url postgres://app@db/shop       # before each start
```

`up` holds an advisory lock while it migrates, so two processes starting at
once take turns. `rowtype-migrate dump` writes the schema the migrations
make, through the server's own `pg_dump`.

## Sessions

`Spindle_postgres.Session.store db` keeps [sessions](cookies.md#sessions)
in the table `spindle_sessions`, which the package's own migration makes:

```sh
rowtype-migrate up --source spindle-postgres --url postgres://app@db/shop
```

Two servers sweeping ended sessions at once share the work and never wait
on each other. A table of another name is `Session.store ~table db`, made
by a migration of yours from `Session.schema ~table`.

## Health and metrics

`Spindle_postgres.Pool.check db` is the pool as a readiness check
([Health checks](health.md)), and `Pool.measure pool metrics` its
connections as [metrics](metrics.md), named `postgres` unless given a name.
