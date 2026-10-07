# A database

An application's real work is its database: reading rows into typed values,
writing several rows that must all land or none, and staying up when the
database is slow, busy or briefly gone.

```sh
opam install spindle_postgres
```

```lisp
(libraries spindle spindle_postgres rowtype rowtype-postgres eio_main)
```

## How it works

**A statement is described once.** With `rowtype`, a statement is a value
holding its SQL, the types of its parameters and the type of its rows, so
running it takes an OCaml tuple and answers OCaml values -- no row decoded by
hand, no parameter in the wrong place. Postgres is reached through rowtype's
backend over [postgres-eio](https://github.com/hyphatech/postgres-eio), a
driver in OCaml: no libpq, nothing to link.

**The pool is made where the program starts.** Every connection is opened
before the server listens, so a database that refuses is a server that does
not start, and says why. The routes are a function of the pool; it is never a
dependency, because the request has nothing to say about it.

**Every connection is bounded.** A statement that runs too long and a
transaction left open are ended by Postgres itself, so one bad query cannot
hold a connection, or its locks, for ever. A request that waits too long for
a connection is answered `503`, rather than late.

**A transaction is a function, and its result decides it.** The work runs
inside `Pool.transaction`; `Ok` commits and `Error` rolls back, so a write
that failed halfway is never half kept. The transaction is opened inside the
handler, after every dependency has run, so it holds its rows for the work
alone and never while a body is still arriving.

**A failure is a value with an answer.** A busy pool, a transaction a
concurrent one beat, a broken commit: each is a variant, and
`Spindle_postgres.refusal` turns any you do not handle yourself into the
right status, the detail in the log.

## A pool, and a read

```ocaml
--8<-- "sql_query.ml:query"
```

The pool is made before the server, and the routes are given it:

```ocaml
--8<-- "sql_query.ml:pool"
```

```sh
$ docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18-alpine
$ curl localhost:8080/
["postgres","template0","template1"]
```

A database that is not there stops the server before it listens:

```
{"level":"error","logger.name":"spindle.postgres","message":"the pool could not be opened: Eio.Io Net Connection_failure Refused Unix_error (Connection refused, \"connect\", \"\")"}
```

??? example "The whole program"

    ```ocaml
    --8<-- "sql_query.ml"
    ```

## A write, in one transaction

Claiming a name is an insert and a read in one transaction; the answer is
`201` the first time and `200` every time after:

```ocaml
--8<-- "sql_transaction.ml:claim"
```

```sh
$ curl -i -X PUT localhost:8080/names/ada
HTTP/1.1 201 Created

{"name":"ada","claimed_at":1790846320191}
$ curl -i -X PUT localhost:8080/names/ada
HTTP/1.1 200 OK

{"name":"ada","claimed_at":1790846320191}
```

??? example "The whole program"

    ```ocaml
    --8<-- "sql_transaction.ml"
    ```

## The pool

A statement is [`rowtype`](https://github.com/hyphatech/rowtype)'s, described once and
run by its Postgres backend, `Rowtype_postgres`; what a transaction is, and
what its failures mean, is the backend's too. What a server adds is how its
connections are bounded, a pool lent a request at a time, and what a failure
answers:

`Spindle_postgres.connect ~sw ~net ~mono_clock` opens one bounded: a statement
past `statement_timeout_ms` (10 000) and a transaction left idle past
`idle_in_transaction_timeout_ms` (30 000) are ended by the server, so a hung
query or a forgotten transaction cannot hold a pooled connection and its
locks. The bounds are start-up parameters, beside `DateStyle=ISO` and
whatever an application adds with `~parameters`, so a connection made again
keeps every one; connecting waits `connect_timeout_s` (10) unless the
connection string says otherwise. `~timeout_s`, the bound on every read and
write, and `~statement_cache` are the driver's, passed through:
`~statement_cache:0` is for a pooler in front of Postgres that cannot carry
named statements.

`Spindle_postgres.Pool` is the backend's pool (`Rowtype_postgres.Pool`), each
connection bounded so, and its options passed through with their own
defaults -- its clock under the name the rest of Spindle gives one,
`~mono_clock`. It makes every connection at startup, so a database
that refuses is a server that does not start. A borrow that waits past
`wait_s` is `` `Busy ``, which `Spindle_postgres.refusal` answers as a `503`:
an overloaded server says so instead of answering late. A borrow whose request
goes away -- a client gone, a drain past its deadline -- has its work ended at
the server, so it fails at once and rolls back instead of finishing a slow
query nobody is waiting for. `Pool.check` is the pool as a readiness check
([Health probes](../guide/health.md)), and `Pool.stats` how it stands.

A program's pool is `Pool.run`, which takes what it needs from `env` as
`serve` does and lends the pool for as long as its body runs:

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Spindle_postgres.Pool.run env "postgres://localhost/app" @@ fun pool ->
  Spindle.serve env (routes pool)
```

It closes the pool when the body returns. A pool that cannot be opened is an
`error` line saying why and an exit with status 1, since a server that cannot
reach its database has nothing to serve; `Pool.create` is the same pool on a
switch the caller gives, answering a `result`, for a program that decides
otherwise.

`Pool.query` is one statement on a borrowed connection, the read that is
the whole of its work, and `Pool.use` a borrow for several; each gives the
connection back when it returns. `Pool.transaction` is a borrow and one
transaction on it: the work answers a `result`, and `Ok` commits and `Error`
rolls back. The transaction's own failures join the work's error type as an
open polymorphic variant, as `Eio.Time.with_timeout` adds `` `Timeout ``, so
a write is its statements and one match:

```ocaml
let sign_up pool ~name ~email =
  Spindle_postgres.Pool.transaction pool (fun db ->
      let* id = Pg.run db add_user (name, email) in
      let* () = Pg.run db log_event (id, "signed_up") in
      Ok id)
  |> function
  | Ok id -> Ok id
  | Error (`Conflict (Some "users_email_key")) ->
      Error (Refusal.make email_taken "That address is taken.")
  | Error e -> Error (Spindle_postgres.refusal e)
```

An application whose own errors are ordinary variants, which cannot take
these in, maps them once, in a bracket of its own, and every transaction goes
through it:

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

`Spindle_postgres.refusal` is the default wording for whatever the route does
not answer itself, and it is an ordinary function a route may pass over:

- **`` `Busy ``** -- no connection within the wait: `503 busy` with
  `Retry-After: 1`.
- **`` `Not_serializable ``** -- a transaction a concurrent one won, that its
  retries did not get past: `503 busy` too, since asking again may succeed.
- **`` `Not_committed ``** -- the transaction could not begin, its `COMMIT`
  failed (a deferred constraint is checked there), or the work answered `Ok`
  in a transaction a failed statement had already aborted: an error the work
  swallowed, which Postgres would otherwise roll back in silence. The same
  failure *returned* as a refusal is the work's own answer, and is kept. A
  `500`, the detail in the log.
- **`` `Lost ``** -- the connection failed with a statement or the `COMMIT`
  in flight, so the work may have landed: a `500`, the detail in the log,
  since asking again blindly could do it twice.
- **`` `Conflict ``, `` `Closed `` and `` `Db ``** -- a `500`, the detail in
  the log. A conflict the route did not name is its surprise, and a `409` it
  never declared would be a code it cannot answer; a route that expects one
  matches it first, by its constraint.

`Pool.transaction` takes the backend's `~keep` -- a refusal keeps nothing it
wrote unless told -- `~isolation` and `~retries`
([`Rowtype_postgres.Transaction`](https://github.com/hyphatech/rowtype)), and a connection the server
dropped is revived before the transaction begins, so a Postgres restart costs
no request.

Migrating is not the server's: `rowtype-migrate up` applies the files
before a build that needs them starts, and the server knows nothing of
them
([`Rowtype_migrate`](https://github.com/hyphatech/rowtype)).

**Sessions in the database** are `Spindle_postgres.Session.store pool
~table`, a `Spindle.Session.store` over a table the application makes in a
migration of its own from `Session.schema ~table`; `Session.statements` are
its statements, for `Rowtype_postgres.verify` beside the application's
others. Each call borrows a connection of its own, since a session is data
about a visit and not a row a handler's transaction must agree with.

## Brackets: why a transaction is not a dependency

A transaction holds its rows -- in a write, the row everybody else writing
there queues on -- for as long as it is open, so nothing inside one waits on
anything but the database. A body read off the socket inside one would hold
them for as long as the client takes to send it. So the dependencies run
first, and the work runs *inside* an explicit function that owns the
connection:

```ocaml
let add_item ~pool =
  Spindle.post (order Path.(s "items")) ~refuses:[ conflict ]
    (Returns.json ~status:`Accepted receipt_json)
    (let+ id = Spindle.param order_id
     and+ token = Spindle.Cookie.optional cart          (* a credential, not yet a customer *)
     and+ item = Spindle.json item_json
     and+ now = Spindle.now in
     match
       Spindle_postgres.Pool.transaction pool (fun db ->
           (* one transaction: the credential proven, the item written *)
           ...)
     with
     | Ok receipt ->
         publish id receipt;  (* on the fiber, and only once it is kept *)
         Ok receipt
     | Error e -> Error (refusal_of e))
```

The shape -- list first, bracket second -- is a convention the types do not
force (a `Dep.of_request` *could* open a transaction), which is why a
dependency should hand over a credential and never a resolved identity:
resolving is a read, and a read belongs inside the bracket, in the same
transaction as the work it authorises -- a row read before the bracket and
written inside it is a race between the two.

- **What is not the database waits for the commit.** A publish, a stream
  or a call to another server is the line after the bracket returns: it runs
  once the work is kept, a refused bracket never reaches it, and the
  transaction holds its rows for none of it.
- **What the bracket may refuse with is the route's `~refuses`**, like any
  code the handler gives.
- **A bracket that reads and writes the same thing** is one function the
  handler calls, however many reads it takes; nothing about it needs
  declaring for the route to be listed whole.

Next: [describing the API](describing.md).
