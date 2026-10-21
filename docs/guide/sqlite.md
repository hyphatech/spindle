# SQLite

`spindle-sqlite` is a server's SQLite: a pool of connections to one file,
the probe that asks it, sessions in a table, and the refusal a database
failure answers. The [Database](../tutorial/database.md) tutorial uses it
throughout; this page is its settings, and when SQLite is the database to
choose.

```sh
opam install spindle-sqlite rowtype-migrate
```

## When to choose SQLite

SQLite is a library, not a server: the database is a file beside your
program, and a statement is a call into it, with no network between.

- **One machine.** Every instance of the server opens the same file, so they
  run on one machine -- as many processes and domains as it has, but one
  host. A server spread across machines wants [Postgres](postgres.md).
- **One writer at a time.** Reads run side by side, and beside a write;
  writes take turns, each holding the file's write lock until it commits.
  Short transactions keep the turns short.
- **Nothing to run.** No server to start, secure or upgrade, and a backup is
  a copy of the file -- `sqlite3 app.db ".backup backup.db"` while the
  server runs.

## The pool

`Spindle_sqlite.Pool.run env file f` opens every connection before the
server listens, and a file that cannot be opened stops the program, saying
why:

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Spindle_sqlite.Pool.run env "app.db" @@ fun pool ->
  Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
```

| Option | Default | |
|---|---|---|
| `~size` | 8 | connections, all opened at start-up |
| `~wait` | 5 s | a borrow waiting longer is `` `Pool `Busy ``, a `503` |
| `~timeout` | 5 s | a statement waiting longer for another's write lock is `` `Not_serializable ``, a `503` |

The durations are `Mtime.Span.t`s, written `Mtime.Span.(2 * s)`.
`Pool.create ~sw ~mono_clock file` is the same pool answering a `result`,
for a program that can go on without its database. A database in memory,
`":memory:"`, is refused: each connection would have one of its own.

**WAL mode.** The pool puts the file in WAL mode as it opens, and the file
keeps it: a read never waits for a write, and a write never waits for the
reads. SQLite keeps two files beside the database while it is open,
`app.db-wal` and `app.db-shm`; they are part of it.

**Off the domain.** SQLite's calls block, on the disk and on another
connection's lock, so each statement runs on a system thread, and the
domain's other requests go on meanwhile.

## Transactions

`Pool.transaction pool (fun db -> ...)` runs one transaction: `Ok` commits,
`Error` rolls back. `~behaviour` says when it takes the write lock:

- `Deferred`, the default: at its first write. Right for a transaction that
  only reads, or only writes.
- `Immediate`: as it begins. Right for one that reads and then writes,
  which begun deferred could find that another wrote since it read --
  `` `Not_serializable ``, however long it waits.
- `Exclusive`: as it begins, keeping readers out too, outside WAL mode.

`~retries:3` runs the whole transaction again when it meets
`` `Not_serializable ``; the work runs again in full, so keep anything that is
not a statement out of it. `~keep` commits an `Error` it says to keep, as
on Postgres.

## Migrations

The tables are `rowtype-migrate`'s, made before the server starts:

```sh
rowtype-migrate create --url sqlite:app.db   # once: makes the file
rowtype-migrate up --url sqlite:app.db       # before each start
rowtype-migrate status --url sqlite:app.db --check
```

`up` runs each migration in a transaction that takes the write lock and
reads the record first, so two processes starting at once never apply one
twice. `rowtype-migrate dump --url sqlite:app.db` writes the
schema the migrations make, needing no server, for a reviewer to read.

## Sessions

`Spindle_sqlite.Session.store db` keeps [sessions](cookies.md#sessions) in
the table `spindle_sessions`, which the package's own migration makes:

```sh
rowtype-migrate up --source spindle-sqlite --url sqlite:app.db
```

`--source` applies the package's migrations before yours, as a history of
their own, so they never interleave with your files. A table of another
name is `Session.store ~table db`, made by a migration of yours from
`Session.schema ~table`.

## Health and metrics

`Spindle_sqlite.Pool.check db` is the pool as a readiness check
([Health checks](health.md)), and `Pool.measure pool metrics` its
connections as [metrics](metrics.md), named `sqlite` unless given a name.
