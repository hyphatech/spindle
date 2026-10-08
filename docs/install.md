# Install

You need **opam**, OCaml's package manager, and **OCaml 5.4 or later**.
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

    Check `ocaml -version`. If it is older than 5.4, make a switch -- an
    environment of its own -- with the latest OCaml:

    ```sh
    opam switch create spindle ocaml-base-compiler
    eval $(opam env)
    ```

## 3. Install Spindle

```sh
opam pin add https://github.com/hyphatech/spindle.git
```

This installs its three packages and everything they need:

| Package | Library | What for |
|---|---|---|
| `spindle` | `spindle` | The framework, and `spindle.client` for calling other servers |
| `spindle_postgres` | `spindle_postgres` | [Database](tutorial/database.md) |
| `spindle_cli` | `spindle_cli` | [Client schemas](tutorial/client-schemas.md#setting-up-the-command-line) |

## Check it worked

```sh
ocaml -version
```

```text
The OCaml toplevel, version 5.5.1
```

```sh
dune --version
```

```text
3.18.0
```

OCaml 5.4 or later and dune 3.18 or later means you are ready.

## Your editor

For completion, types on hover and errors as you type, install the language
server, then the **OCaml Platform** extension in VS Code -- or the OCaml
support of your editor:

```sh
opam install ocaml-lsp-server
```

Next: [your first app](tutorial/first-app.md).
