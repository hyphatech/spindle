# Database

Read rows into typed values, write several rows that all land or none, and
answer sensibly when the database is slow or busy. Statements are
[`rowtype`](https://github.com/hyphatech/rowtype)'s: each is a value holding
its SQL and the types of its parameters and rows, run through a pure-OCaml
Postgres driver with nothing to link.

```lisp
(libraries spindle spindle_postgres rowtype rowtype-postgres eio_main)
```

## Connecting and querying

```ocaml
--8<-- "sql_query.ml:query"
```

Make the pool where the program starts, and give it to the routes:

```ocaml
--8<-- "sql_query.ml:pool"
```

```sh
docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
```

```sh
curl localhost:8080/
```

```text
["postgres","template0","template1"]
```

`Pool.run` opens every connection before the server listens, so a database
that is not there stops the server with exit code 1, saying why:

```
{"level":"error","logger.name":"spindle.postgres","message":"the pool could not be opened: Eio.Io Net Connection_failure Refused Unix_error (Connection refused, \"connect\", \"\")"}
```

??? example "The whole app"

    ```ocaml
    --8<-- "sql_query.ml"
    ```

## Transactions

Claiming a name is an insert and a read in one transaction; the answer is
`201` the first time and `200` every time after:

```ocaml
--8<-- "sql_transaction.ml:claim"
```

```sh
curl -i -X PUT localhost:8080/names/ada
```

```text
HTTP/1.1 201 Created

{"name":"ada","claimed_at":1791451486621}
```

```sh
curl -i -X PUT localhost:8080/names/ada
```

```text
HTTP/1.1 200 OK

{"name":"ada","claimed_at":1791451486621}
```

`Pool.transaction` borrows a connection and runs your function in one
transaction: `Ok` commits, `Error` rolls back. `let*` here is
`Result.bind`, defined in the program.

??? example "The whole app"

    ```ocaml
    --8<-- "sql_transaction.ml"
    ```

## Pool settings

`Spindle_postgres.Pool` is rowtype's pool with server-friendly bounds:

- `Pool.query pool statement params` -- one statement, for a read that is the
  whole of the work.
- `Pool.transaction pool (fun db -> ...)` -- one transaction; takes
  `~isolation`, `~retries` and `~keep`.
- `Pool.use pool (fun db -> ...)` -- a borrowed connection for several
  statements outside a transaction.
- `Pool.check` -- the pool as a readiness check ([Health
  probes](../guide/health.md)); `Pool.stats` and `Pool.measure` for metrics.
- `Pool.create ~sw ~net ~mono_clock` -- the same pool answering a `result`,
  for a program that can go on without its database.

Every connection is bounded, so one bad query cannot hold a connection and
its locks for ever:

| Option | Default | |
|---|---|---|
| `~statement_timeout_ms` | 10 000 | a statement running longer is ended by Postgres |
| `~idle_in_transaction_timeout_ms` | 30 000 | so is a transaction left open and idle |
| `~connect_timeout_s` | 10 | unless the connection string says `connect_timeout` |
| `~size` | 8 | connections, all opened at start-up |
| `~wait_s` | 5 | a borrow waiting longer is `` `Busy ``, a `503` |

`~statement_cache:0` is for a pooler in front of Postgres that cannot carry
named statements.

**Sessions in the database** are `Spindle_postgres.Session.store pool
~table`, over a table you create in a migration from
`Session.schema ~table`. Migrations are
[`rowtype-migrate`](https://github.com/hyphatech/rowtype)'s, run before the
server starts.

## Database errors

A failure is a variant, and `Spindle_postgres.refusal` turns any you do not
handle into a status, with the detail in the log:

- `` `Busy `` (no connection within the wait) and `` `Not_serializable ``
  (a concurrent transaction won, past its retries): `503 busy` with
  `Retry-After: 1`, since asking again may succeed.
- Everything else -- `` `Conflict ``, `` `Lost ``, `` `Not_committed ``,
  `` `Db ``, ... -- `500 internal`.

Handle the ones you expect first. A unique-constraint violation is a
`` `Conflict `` with the constraint's name:

```ocaml
let sign_up pool ~name ~email =
  Spindle_postgres.Pool.transaction pool (fun db ->
      let* id = Pg.run db add_user (name, email) in
      let* () = Pg.run db log_event (id, "signed_up") in
      Ok id)
  |> function
  | Ok id -> Ok id
  | Error (`Conflict (Some "users_email_key")) ->
      Error (Spindle.Refusal.make email_taken "That address is taken.")
  | Error e -> Error (Spindle_postgres.refusal e)
```

Declare `email_taken` in the route's `~refuses`. The transaction's failures
join your work's error type as polymorphic variants; if your own errors are
an ordinary variant, wrap the work's errors once:

```ocaml
let transaction pool ~failed work =
  match
    Spindle_postgres.Pool.transaction pool (fun db ->
        Result.map_error (fun e -> `Work e) (work db))
  with
  | Ok v -> Ok v
  | Error (`Work e) -> Error e
  | Error ((`Busy | #Rowtype_postgres.Transaction.failure) as f) ->
      Error (failed f)
```

## Why a transaction is not a dependency

A transaction holds its rows locked while it is open. So let the
dependencies run first -- the body read, the cookies parsed -- and open the
transaction inside the handler, around the database work alone:

```ocaml
let add_item pool =
  Spindle.post
    Spindle.Path.(s "orders" / order_id / s "items")
    (Spindle.Returns.json ~status:`Created item_json)
    (let+ id = Spindle.param order_id
     and+ item = Spindle.json item_json in
     match
       Spindle_postgres.Pool.transaction pool (fun db ->
           let* () = Pg.run db reserve (id, item.sku) in
           let* () = Pg.run db insert_item (id, item.sku, item.quantity) in
           Ok item)
     with
     | Ok item ->
         notify id item; (* only once the work is committed *)
         Ok item
     | Error e -> Error (Spindle_postgres.refusal e))
```

- **Read inside, not before.** A dependency hands over a credential (a cookie,
  a token), never a resolved user: a row read before the transaction and
  written inside it is a race.
- **What is not the database comes after.** A publish, a stream or a call to
  another server goes after the transaction returns, so it runs only once
  the work is kept.

Next: [OpenAPI](openapi.md).
