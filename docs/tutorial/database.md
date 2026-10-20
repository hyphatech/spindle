# Database

Read rows into typed values, write several rows that all land or none, and
answer sensibly when the database is slow or busy. Statements are
[`rowtype`](https://github.com/hyphatech/rowtype)'s: each is a value holding
its SQL and the types of its parameters and rows, run through a pure-OCaml
Postgres driver with nothing to link.

Install the package, which brings `rowtype` and `rowtype-postgres` with it:

```sh
opam install spindle-postgres
```

Add the libraries to your `bin/dune`. The preprocessor is the one from
[your first app](first-app.md), for `[@@deriving wiretype]`:

```lisp
(executable
 (name main)
 (libraries spindle spindle-postgres rowtype rowtype-postgres eio_main)
 (preprocess (pps ppx_wiretype)))
```

To try the examples, start a throwaway Postgres in Docker. It listens on
port 5432, with the user and password `postgres`, and is deleted when you
stop it:

```sh
docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
```

## Connecting and querying

A statement is a value: its SQL, the type of its parameters and the type of
each row. `Pool.exec` runs it on a connection borrowed from the pool, and
`Spindle_postgres.refusal` turns a database failure into an answer (see
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

Make the pool where the program starts, from a connection string, and
supply it to the server with `~resources`:

```ocaml
let database = "postgres://postgres:postgres@localhost:5432/postgres"

--8<-- "sql_query.ml:pool"
```

A route that reads a resource the server was not given stops the program
before it listens, naming the route and the resource. A test supplies its
own pool, or none for a route that reads none
([Testing](../guide/testing.md)), and the [command
line](client-schemas.md) describes the routes with no database at all.

Run it from the repository's root, then ask for `/`:

```console
$ dune exec examples/sql_query.exe
$ curl localhost:8080/
["postgres","template0","template1"]
```

`Pool.run` opens every connection before the server listens. If the
database is not there, the program logs why and exits with status 1:

```
{"timestamp":"2026-10-16T09:24:46.621Z","level":"error","logger.name":"spindle-postgres","message":"the pool could not be opened: Eio.Io Net Connection_failure Refused Unix_error (Connection refused, \"connect\", \"\")"}
```

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

??? example "The whole app"

    ```ocaml
    --8<-- "sql_transaction.ml"
    ```

## Pool settings

`Spindle_postgres.Pool` is rowtype's pool with server-friendly bounds:

- `Pool.exec pool statement params` -- one statement, as rowtype's `run`
  runs it, for a read that is the whole of the work. (`Pool.run` is the
  program's pool, above.)
- `Pool.transaction pool (fun db -> ...)` -- one transaction; takes
  `~isolation`, `~retries` and `~keep`. A transaction is never run again
  unless you ask: at `~isolation:Serializable`, pass `~retries:3` to run it
  again when Postgres reports a conflict with a concurrent one
  (`` `Not_serializable ``). The work runs again in full, so keep anything
  that is not a statement out of it.
- `Pool.use pool (fun db -> ...)` -- a borrowed connection for several
  statements outside a transaction.
- `Pool.check db` -- the pool as a readiness check ([Health
  checks](../guide/health.md)); `Pool.stats` and `Pool.measure` for
  [metrics](../guide/metrics.md).
- `Pool.create ~sw ~net ~mono_clock target` -- the same pool answering a
  `result`, for a program that can go on without its database. `target` is a
  `Rowtype_postgres.Conninfo.t`, read from a connection string by
  `Conninfo.of_string`; `Pool.run` takes the string and reads it once.

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
`Mtime.Span.(2 * s)`. Connecting waits
10 s for each address unless the connection string says `connect_timeout`
(`Conninfo.with_connect_timeout`). Postgres is given
the two bounds in whole milliseconds, rounded up, so a span under a
millisecond is still a bound; a span of zero lifts one, as Postgres's `0`
does.

`~statement_cache:0` is for a pooler in front of Postgres that cannot carry
named statements.

**[Sessions](../guide/cookies.md#sessions) in the database** are
`Spindle_postgres.Session.store db ~table`, over a table you create in a
migration from `Session.schema ~table`, read through `db` as every route
reads the pool:
`Spindle.Session.create ~store:(Spindle_postgres.Session.store db ~table:"sessions") ...`. Migrations are
[`rowtype-migrate`](https://github.com/hyphatech/rowtype)'s, run before the
server starts.

## Database errors

A failure is a variant, and `Spindle_postgres.refusal` turns any you do not
handle into a status, with the detail in the log:

- `` `Pool `Busy `` (no connection within the wait), `` `Unsent `` (the
  database could not be reached, so nothing was done), `` `Pool `Closed ``
  (the pool is closed, answered at once) and `` `Not_serializable ``
  (a concurrent transaction won, past its retries): `503 busy` with
  `Retry-After: 1`, since asking again may succeed. The two `` `Pool ``
  states and `` `Unsent `` are logged as warnings, not errors: a server
  under load, shutting down or cut off from its database is not a broken
  one.
- Everything else -- `` `Conflict ``, `` `Lost ``, `` `Not_committed ``,
  `` `Db ``, a closed connection, ... -- `500 internal`.

Where a failure is logged rather than answered,
`Spindle_postgres.error_to_string` describes it in words, without any
parameter's value. Here the program cannot create its table, so it logs
why and exits:

```ocaml
--8<-- "sql_transaction.ml:log"
```

Handle the ones you expect first. A unique-constraint violation is a
`` `Conflict `` with the constraint's name, whether a statement found it or
a constraint declared `DEFERRABLE` refused the transaction's `COMMIT`:

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
    Spindle_postgres.Pool.transaction pool (fun db ->
        Result.map_error (fun e -> `Work e) (work db))
  with
  | Ok v -> Ok v
  | Error (`Work e) -> Error e
  | Error ((`Pool _ | #Rowtype_postgres.Transaction.failure) as f) ->
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
