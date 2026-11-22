# Install

It needs opam, with a switch of OCaml 5.5 or later.

```sh
opam repo add open-opam https://github.com/open-opam/opam-repository.git
opam install spindle
```

This installs the framework and everything it needs, `dune` and the
`ppx_wiretype` deriver included. The database and the command line are
packages of their own, so an app that uses neither never installs them;
their tutorials install them when you get there:

| Package | Libraries | What for |
|---|---|---|
| `spindle` | `spindle`, and with it `spindle-http` and `spindle-client` | The framework, HTTP itself, and a client for calling other servers |
| `spindle-sqlite` | `spindle-sqlite` | [Database](tutorial/database.md), on SQLite ([guide](guide/databases.md#sqlite)) |
| `spindle-postgres` | `spindle-postgres` | [Database](tutorial/database.md), on Postgres ([guide](guide/databases.md#postgres)) |
| `spindle-cli` | `spindle-cli` | [Client schemas](tutorial/client-schemas.md#setting-up-the-command-line) |

A program names the libraries it uses in its `dune` file;
[your first app](tutorial/first-app.md) writes one, next.
