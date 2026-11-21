# Database

Read rows into typed values, write several rows that all land or none, and
answer sensibly when the database is busy. Statements are
[`rowtype`](https://hyphatech.github.io/rowtype/)'s: a value holding its SQL
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
-- create_names: the names sql_query lists and sql_transaction claims.

create table names (
  name text primary key,
  claimed_at text not null
) strict;
```

Make the database and apply the migration:

```console
$ rowtype-migrate create --url sqlite:names.db
$ rowtype-migrate up --url sqlite:names.db
```

Run `up` before the server starts, never from the server: every instance
of it would race to apply the same file.
[rowtype's guide to migrations](https://hyphatech.github.io/rowtype/guide/migrations/) covers the
rest of the command.

## 3. Read rows

A statement says its SQL, its parameters and the type of each row.
`Pool.exec` runs it on a connection borrowed from the pool, and
`Spindle_sqlite.refusal` turns a failure into an answer:

```ocaml title="names_query.ml"
(* The statement sql_query runs, and the handler that runs it on a pool. *)

module S = Rowtype

let claimed =
  S.list ~params:S.unit ~row:S.text "select name from names order by name"

(* A borrow that waits past the pool's limit is [`Pool `Busy], which [refusal]
   answers 503: an overloaded server says so rather than answering late. *)
let list_names pool =
  Spindle_sqlite.Pool.exec pool claimed ()
  |> Result.map_error Spindle_sqlite.refusal
```

A route reads the pool as a dependency, `db`, made once with
`Dep.of_resource`. The routes are then a plain value that exists before any
database does:

```ocaml title="names_routes.ml"
(* The routes sql_query serves, reading the pool as a dependency. *)

open Spindle.Syntax

(* The pool, as the routes read it: supplied where the server starts. *)
let db : Spindle_sqlite.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

let routes =
  [
    Spindle.get
      Spindle.Path.(s "names")
      (Spindle.Returns.json (Wiretype.list Wiretype.string))
      (let+ pool = db in
       Names_query.list_names pool);
  ]
```

The program makes the pool from the database's file and hands it to the
server with `~resources`:

```ocaml title="sql_query.ml"
(* A pool of connections to a SQLite file, and a route that runs a statement
   on it: /names answers the names claimed, which sql_transaction claims.

     rowtype-migrate create --url sqlite:names.db
     rowtype-migrate up --dir examples/migrations --url sqlite:names.db
     dune exec examples/sql_query.exe *)

(* The pool opens every connection at once, so a file that cannot be opened
   is a server that does not start. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_sqlite.Pool.run env "names.db" @@ fun pool ->
  Spindle.serve env
    ~resources:[ Spindle.Dep.resource Names_routes.db pool ]
    Names_routes.routes
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

## 4. Write in a transaction

Claiming a name is an insert and a read in one transaction. The answer is
`201` the first time and `200` every time after:

```ocaml title="name_claim.ml"
(* Claiming a name, in one transaction: the write sql_transaction's route
   makes. *)

open Spindle.Syntax
module S = Rowtype
module Sq = Rowtype_sqlite

type claim = { name : string; claimed_at : Ptime.t } [@@deriving wiretype]

(* The database says whether this request made the row: an insert that meets
   one already there changes nothing, and counts none. *)
let insert_name =
  S.exec_count ~params:(S.t2 S.text S.instant)
    "insert into names (name, claimed_at) values ($1, $2) on conflict (name) \
     do nothing"

let when_claimed =
  S.find ~params:S.text ~row:S.instant
    "select claimed_at from names where name = $1"

(* One transaction, so the name is claimed and read in one go: [Ok] commits
   both statements and a failure rolls both back. *)
let claim pool name ~now =
  Spindle_sqlite.Pool.transaction ~behaviour:Immediate pool (fun db ->
      let* made = Sq.run db insert_name (name, now) in
      let* claimed_at = Sq.run db when_claimed name in
      Ok ((if made = 1 then `Created else `OK), { name; claimed_at }))
  |> Result.map_error Spindle_sqlite.refusal
```

`Pool.transaction` borrows a connection and runs the function in one
transaction. `Ok` commits and `Error` rolls back. `~behaviour:Immediate`
takes SQLite's write lock as the transaction begins, which a transaction
that reads and then writes needs.

The handler returns the status beside the value, so the route lists both
with `Returns.json_response`, as `sql_transaction.ml` below does.

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

The rest of the app: its route and its server

```ocaml title="sql_transaction.ml"
(* A write in one transaction, and an answer that says what became of it:
   PUT /names/{name} claims a name, 201 the first time and 200 every time
   after, with when it was first claimed.

     rowtype-migrate create --url sqlite:names.db
     rowtype-migrate up --dir examples/migrations --url sqlite:names.db
     dune exec examples/sql_transaction.exe
     curl -i -X PUT localhost:8080/names/ada     201
     curl -i -X PUT localhost:8080/names/ada     200 *)

open Spindle.Syntax

let name = Spindle.Path.string "name"

let db : Spindle_sqlite.Pool.t Spindle.Dep.t =
  Spindle.Dep.of_resource "database"

(* Every branch returns the status it reached, and the route lists each with
   when it happens, which is what the API's document says of it. *)
let routes =
  [
    Spindle.put ~summary:"Claim a name"
      Spindle.Path.(s "names" / name)
      (Spindle.Returns.json_response Name_claim.claim_json
         ~statuses:
           [
             (`Created, "The name was free, and is now claimed.");
             (`OK, "The name was claimed already.");
           ])
      (let+ pool = db and+ name = Spindle.param name and+ now = Spindle.now in
       Name_claim.claim pool name ~now);
  ]

(* The table is the migration's, made before the server starts: a server
   that made it would race every other instance of itself to. *)
let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_sqlite.Pool.run env "names.db" @@ fun pool ->
  Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
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

`Spindle_sqlite.Session.store db` keeps
[sessions](../guide/cookies.md#sessions) in the table
`spindle_sessions`. The package ships the migration that makes it, and
`--source` applies it before yours:

```console
$ rowtype-migrate up --source spindle-sqlite --url sqlite:names.db
```
