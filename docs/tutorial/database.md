# Database

Read rows into typed values, write several rows that all land or none, and
answer sensibly when the database is slow or busy. Statements are
[`rowtype`](https://github.com/hyphatech/rowtype)'s: each is a value holding
its SQL and the types of its parameters and rows, and the same statement
runs on SQLite or on Postgres.

This tutorial uses **SQLite**, a database in one file, which needs no server
to start. Everything here works the same on Postgres with `Spindle_postgres`
in place of `Spindle_sqlite`; [SQLite](../guide/sqlite.md) and
[Postgres](../guide/postgres.md) each have a guide of their own, with their
settings and when to choose them.

Install the package, which brings `rowtype` and `rowtype-sqlite` with it,
and `rowtype-migrate`, the command that makes the tables:

```sh
opam install spindle-sqlite rowtype-migrate
```

Add the libraries to your `bin/dune`. The preprocessor is the one from
[your first app](first-app.md), for `[@@deriving wiretype]`:

```lisp
(executable
 (name main)
 (libraries spindle spindle-sqlite rowtype rowtype-sqlite eio_main)
 (preprocess (pps ppx_wiretype)))
```

## Making the tables

A table is made by a migration: a SQL file in `migrations/`, applied by
`rowtype-migrate` before the server starts, and never by the server, since
every instance of it would race to. `new` names one for you:

```console
$ rowtype-migrate new create_names
migrations/20261021000000_create_names.sql
```

```sql
--8<-- "migrations/20261021000000_create_names.sql"
```

`create` makes the database, here a file, and `up` applies every migration
it has not recorded, each in a transaction of its own:

```console
$ rowtype-migrate create --url sqlite:names.db
$ rowtype-migrate up --url sqlite:names.db
$ rowtype-migrate status --url sqlite:names.db
applied  20261021000000_create_names
```

A migration is forward only, and one that has run is never edited: the
next change is the next file. `rowtype-migrate` refuses a database whose
record disagrees with the files, naming the migration, before it changes
anything; its [README](https://github.com/hyphatech/rowtype#migrations) says
the rest.

## Connecting and querying

A statement is a value: its SQL, the type of its parameters and the type of
each row. `Pool.exec` runs it on a connection borrowed from the pool, and
`Spindle_sqlite.refusal` turns a database failure into an answer (see
[Database errors](#database-errors)):

```ocaml
--8<-- "sql_query.ml:query"
```

The routes read the pool as a dependency, `db`, made once with
`Dep.of_resource`. It is a resource: the application's, not the request's,
so the routes are a plain value that exists before any database does:

```ocaml
--8<-- "sql_query.ml:routes"
```

Make the pool where the program starts, from the database's file, and
supply it to the server with `~resources`:

```ocaml
--8<-- "sql_query.ml:pool"
```

A route that reads a resource the server was not given stops the program
before it listens, naming the route and the resource. A test supplies its
own pool, or none for a route that reads none
([Testing](../guide/testing.md)), and the [command
line](client-schemas.md) describes the routes with no database at all.

Run it from the repository's root, with the database made from
`examples/migrations`, then ask for `/names`:

```console
$ rowtype-migrate create --url sqlite:names.db
$ rowtype-migrate up --dir examples/migrations --url sqlite:names.db
$ dune exec examples/sql_query.exe
$ curl localhost:8080/names
[]
```

`Pool.run` opens every connection before the server listens. If the file
cannot be opened, the program logs why and exits with status 1.

??? example "The whole app"

    ```ocaml
    --8<-- "sql_query.ml"
    ```

## Transactions

Claiming a name is an insert and a read in one transaction. The answer is
`201` the first time and `200` every time after:

```ocaml
--8<-- "sql_transaction.ml:claim"
```

The handler returns the status together with the value,
`` (`Created, claim) `` or `` (`OK, claim) ``. A route whose status is chosen
at run time says so with `Returns.json_response`, listing each status it may
answer and when (see [Request bodies, responses and
errors](bodies.md)):

```ocaml
Spindle.Returns.json_response claim_json
  ~statuses:
    [
      (`Created, "The name was free, and is now claimed.");
      (`OK, "The name was claimed already.");
    ]
```

```console
$ curl -i -X PUT localhost:8080/names/ada
HTTP/1.1 201 Created
...

{"name":"ada","claimed_at":"2026-10-08T09:24:46.621Z"}

$ curl -i -X PUT localhost:8080/names/ada
HTTP/1.1 200 OK
...

{"name":"ada","claimed_at":"2026-10-08T09:24:46.621Z"}
```

`Pool.transaction` borrows a connection and runs your function in one
transaction: `Ok` commits, `Error` rolls back. `let*` here is
`Result.bind`, from `open Spindle.Syntax` with `let+` and `and+`.
`~behaviour:Immediate` takes SQLite's write lock as the transaction begins,
which a transaction that reads and then writes wants: begun the default
way, its write could find that another wrote since it read.

??? example "The whole app"

    ```ocaml
    --8<-- "sql_transaction.ml"
    ```

## Database errors

A failure is a variant, and `refusal` turns any you do not handle into a
status, with the detail in the log:

- `` `Pool `Busy `` (no connection within the wait), `` `Pool `Closed ``
  (the pool is closed, answered at once) and `` `Not_serializable `` (a lock
  another held past the wait, or a concurrent transaction that won, past
  its retries): `503 busy` with `Retry-After: 1`, since asking again may
  succeed. The two `` `Pool `` states are logged as warnings, not errors: a
  server under load or shutting down is not a broken one.
- Everything else -- `` `Conflict ``, `` `Not_committed ``, `` `Db ``, a
  closed connection, ... -- `500 internal`.

Where a failure is logged rather than answered, `error_to_string` describes
it in words, without any parameter's value:

```ocaml
match Spindle_sqlite.Pool.exec pool claimed () with
| Ok names -> ...
| Error e ->
    Logs.err (fun m -> m "could not list: %s" (Spindle_sqlite.error_to_string e))
```

Handle the ones you expect first. A unique-constraint violation is a
`` `Conflict `` naming what it refused -- on SQLite the columns,
`users.email`; on Postgres the constraint, `users_email_key`:

```ocaml
let sign_up pool ~name ~email =
  Spindle_sqlite.Pool.transaction pool (fun db ->
      let* id = Sq.run db add_user (name, email) in
      let* () = Sq.run db log_event (id, "signed_up") in
      Ok id)
  |> function
  | Ok id -> Ok id
  | Error (`Conflict (Some "users.email")) ->
      Error (Spindle.Refusal.make email_taken "That address is taken.")
  | Error e -> Error (Spindle_sqlite.refusal e)
```

`email_taken` is a refusal code of your own. Make it once, and list it in
the route's `~refuses` so the route's documentation shows it:

```ocaml
let email_taken =
  Spindle.Refusal.Code.make "email_taken" ~status:`Conflict
    ~doc:"An account already uses this email address."
```

The transaction's failures
join your work's error type as polymorphic variants; if your own errors are
an ordinary variant, wrap the work's errors once:

```ocaml
let transaction pool ~failed work =
  match
    Spindle_sqlite.Pool.transaction pool (fun db ->
        Result.map_error (fun e -> `Work e) (work db))
  with
  | Ok v -> Ok v
  | Error (`Work e) -> Error e
  | Error ((`Pool _ | #Rowtype_sqlite.Transaction.failure) as f) ->
      Error (failed f)
```

## Why a transaction is not a dependency

A transaction holds its rows locked while it is open. So let the
dependencies run first -- the body read, the cookies parsed -- and open the
transaction inside the handler, around the database work alone:

```ocaml
let add_item =
  Spindle.post
    Spindle.Path.(s "orders" / order_id / s "items")
    (Spindle.Returns.json ~status:`Created item_json)
    (let+ pool = db
     and+ id = Spindle.param order_id
     and+ item = Spindle.json item_json in
     match
       Spindle_sqlite.Pool.transaction ~behaviour:Immediate pool (fun db ->
           let* () = Sq.run db reserve (id, item.sku) in
           let* () = Sq.run db insert_item (id, item.sku, item.quantity) in
           Ok item)
     with
     | Ok item ->
         notify id item; (* only once the work is committed *)
         Ok item
     | Error e -> Error (Spindle_sqlite.refusal e))
```

- **Read inside, not before.** A dependency hands over a credential (a cookie,
  a token), never a resolved user: a row read before the transaction and
  written inside it is a race.
- **What is not the database comes after.** A publish, a stream or a call to
  another server goes after the transaction returns, so it runs only once
  the work is kept.

## Sessions in the database

[Sessions](../guide/cookies.md#sessions) kept in the database are
`Spindle_sqlite.Session.store db`, read through `db` as every route reads
the pool. Its table is a migration the package installs: name the package
with `--source`, and `up` applies its migrations before yours, as a history
of their own:

```console
$ rowtype-migrate up --source spindle-sqlite --url sqlite:names.db
```
