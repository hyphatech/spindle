# Install

You need **opam**, OCaml's package manager, and **OCaml 5.5 or later**.
Spindle brings **dune**, the build tool, with it.

## 1. Install opam

=== "macOS"

    ```sh
    brew install opam
    ```

=== "Linux"

    ```sh
    bash -c "sh <(curl -fsSL https://opam.ocaml.org/install.sh)"
    ```

=== "Windows"

    ```powershell
    winget install Git.Git OCaml.opam
    ```

    Spindle should work on Windows, but it is not tested there. If something
    fails, [WSL](https://learn.microsoft.com/windows/wsl/install) gives you a
    Linux to follow the Linux steps in.

## 2. Set up OCaml

```sh
opam init
```

Answer yes when it offers to set up your shell. This installs the latest
OCaml, which takes a few minutes. Then let this terminal see it -- a new
terminal does by itself:

=== "macOS and Linux"

    ```sh
    eval $(opam env)
    ```

=== "Windows"

    ```powershell
    (& opam env) -split '\r?\n' | ForEach-Object { Invoke-Expression $_ }
    ```

??? note "Already had opam?"

    Check `ocaml -version`. If it is older than 5.5, make a switch -- an
    environment of its own -- with the latest OCaml:

    ```sh
    opam switch create spindle ocaml-base-compiler
    eval $(opam env)
    ```

## 3. Install Spindle

```sh
opam repo add hypha https://github.com/hyphatech/opam-repository.git
opam install spindle
```

This installs the framework and everything it needs, `dune` and the
`ppx_wiretype` deriver included. The database and the command line are
packages of their own, so an app that uses neither never installs them;
their tutorials install them when you get there:

| Package | Libraries | What for |
|---|---|---|
| `spindle` | `spindle`, `spindle.http`, `spindle.client` | The framework, HTTP itself, and a client for calling other servers |
| `spindle-sqlite` | `spindle-sqlite` | [Database](tutorial/database.md), on SQLite ([guide](guide/databases.md#sqlite)) |
| `spindle-postgres` | `spindle-postgres` | [Database](tutorial/database.md), on Postgres ([guide](guide/databases.md#postgres)) |
| `spindle-cli` | `spindle-cli` | [Client schemas](tutorial/client-schemas.md#setting-up-the-command-line) |

## Check it worked

```console
$ ocaml -version
The OCaml toplevel, version 5.5.1

$ dune --version
3.24.2

$ opam list spindle
```

It lists `spindle` with a version, not `--`, under *Installed*.

OCaml 5.5 or later, dune 3.18 or later and an installed `spindle` mean you
are ready.

## Your editor

For completion, types on hover and errors as you type, install the language
server, then the **OCaml Platform** extension in VS Code -- or the OCaml
support of your editor:

```sh
opam install ocaml-lsp-server
```

A program names the libraries it uses in its `dune` file;
[your first app](tutorial/first-app.md) writes one, next.
