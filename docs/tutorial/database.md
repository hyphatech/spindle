# Database

Read rows into typed values, write several rows that all land or none, and
answer sensibly when the database is busy. Statements are
[`rowtype`](https://github.com/hyphatech/rowtype)'s: a value holding its SQL
and the types of its parameters and rows.

This page uses SQLite, a database in one file, so there is no server to
start. On Postgres every step is the same with `Spindle_postgres` in place
of `Spindle_sqlite`. [Databases](../guide/databases.md) lists each one's
settings.

## 1. Install

```sh
opam install spindle-sqlite rowtype-migrate
```

`spindle-sqlite` brings `rowtype` and `rowtype-sqlite`. `rowtype-migrate` is
the command that makes your tables. Add the libraries to `bin/dune`:

```lisp
(executable
 (name main)
 (libraries spindle spindle-sqlite rowtype rowtype-sqlite eio_main)
 (preprocess (pps ppx_wiretype)))
```

## 2. Make the table

A table is made by a migration, a SQL file in `migrations/`:

```console
$ rowtype-migrate new create_names
migrations/20261021000000_create_names.sql
```

```sql
--8<-- "migrations/20261021000000_create_names.sql"
```

Make the database and apply the migration:

```console
$ rowtype-migrate create --url sqlite:names.db
$ rowtype-migrate up --url sqlite:names.db
```

Run `up` before the server starts, never from the server: every instance
of it would race to apply the same file. The
[rowtype README](https://github.com/hyphatech/rowtype#migrations) covers the
rest of the command.

## 3. Read rows

A statement says its SQL, its parameters and the type of each row.
`Pool.exec` runs it on a connection borrowed from the pool, and
`Spindle_sqlite.refusal` turns a failure into an answer:

```ocaml
--8<-- "sql_query.ml:query"
```

A route reads the pool as a dependency, `db`, made once with
`Dep.of_resource`. The routes are then a plain value that exists before any
database does:

```ocaml
--8<-- "sql_query.ml:routes"
```

The program makes the pool from the database's file and hands it to the
server with `~resources`:

```ocaml
--8<-- "sql_query.ml:pool"
```

`Pool.run` opens every connection before the server listens. A file that
cannot be opened stops the program, saying why. A route that reads a
resource the server was not given stops it too, naming both.

Run it from the repository's root:

```console
$ rowtype-migrate create --url sqlite:names.db
$ rowtype-migrate up --dir examples/migrations --url sqlite:names.db
$ dune exec examples/sql_query.exe
$ curl localhost:8080/names
[]
```

??? example "The whole app"

    ```ocaml
    --8<-- "sql_query.ml"
    ```

## 4. Write in a transaction

Claiming a name is an insert and a read in one transaction. The answer is
`201` the first time and `200` every time after:

```ocaml
--8<-- "sql_transaction.ml:claim"
```

`Pool.transaction` borrows a connection and runs the function in one
transaction. `Ok` commits and `Error` rolls back. `~behaviour:Immediate`
takes SQLite's write lock as the transaction begins, which a transaction
that reads and then writes needs.

The handler returns the status beside the value, so the route lists both
with `Returns.json_response`:

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

??? example "The whole app"

    ```ocaml
    --8<-- "sql_transaction.ml"
    ```

## 5. Answer failures

`refusal` turns any failure you do not handle into a status, and logs the
detail:

| Failure | Answer |
|---|---|
| `` `Pool `Busy ``, no connection free within the wait | `503`, logged as a warning |
| `` `Pool `Closed ``, the server is shutting down | `503`, logged as a warning |
| `` `Not_serializable ``, a lock held past the wait | `503` |
| anything else | `500` |

A `503` carries `Retry-After: 1`, since asking again may succeed.

Handle the failures you expect before `refusal`. A unique key refused is a
`` `Conflict `` naming the columns, `users.email` on SQLite, or the
constraint, `users_email_key` on Postgres:

```ocaml
match Spindle_sqlite.Pool.exec pool add_user (name, email) with
| Ok id -> Ok id
| Error (`Conflict (Some "users.email")) ->
    Error (Spindle.Refusal.make email_taken "That address is taken.")
| Error e -> Error (Spindle_sqlite.refusal e)
```

`email_taken` is a refusal code of your own, listed in the route's
`~refuses` so its documentation shows it:

```ocaml
let email_taken =
  Spindle.Refusal.Code.make "email_taken" ~status:`Conflict
    ~doc:"An account already uses this email address."
```

To log a failure rather than answer it, `error_to_string` gives its words,
never a parameter's value:

```ocaml
Logs.err (fun m -> m "could not list: %s" (Spindle_sqlite.error_to_string e))
```

If your own errors are an ordinary variant, wrap the work's errors once,
and the transaction's own failures stay apart from them:

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

## 6. Open the transaction in the handler

A transaction holds its rows locked while it is open. Let the dependencies
run first, the body read and the cookies parsed, and open the transaction
inside the handler, around the database work alone:

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

- **Read inside, not before.** A dependency hands over a credential, a
  cookie or a token, never a resolved user: a row read before the
  transaction and written inside it is a race.
- **What is not the database comes after.** A publish, a stream or a call to
  another server goes after the transaction returns, so it runs only once
  the work is kept.

## 7. Keep sessions in the database

`Spindle_sqlite.Session.store db` keeps [sessions](../guide/cookies.md#sessions)
in the table `spindle_sessions`. The package ships the migration that makes
it, and `--source` applies it before yours:

```console
$ rowtype-migrate up --source spindle-sqlite --url sqlite:names.db
```
