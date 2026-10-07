# Install

Three things, once per machine: **opam**, OCaml's package manager; **OCaml**
itself, which opam installs; and **Spindle**, which brings **dune**, the
build tool, with it.

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

## 2. Install OCaml

opam keeps OCaml and your packages in a *switch*, an environment of its own.
Set opam up -- answer yes when it offers to set up your shell -- then make a
switch with OCaml 5.4:

```sh
opam init --bare
opam switch create 5.4.1
```

This compiles OCaml, and takes a few minutes. Then let this terminal see
it; a new one sees it by itself:

=== "macOS and Linux"

    ```sh
    eval $(opam env)
    ```

=== "Windows"

    ```powershell
    (& opam env) -split '\r?\n' | ForEach-Object { Invoke-Expression $_ }
    ```

## 3. Install Spindle

```sh
opam install spindle
```

That is Spindle, dune, and everything they need.

## Check it worked

```sh
$ ocaml -version
The OCaml toplevel, version 5.4.1
$ dune --version
3.18.0
```

Both answering -- dune with 3.18 or later -- means you are ready.

## Your editor

For completion, types on hover and errors as you type, install the language
server, then the **OCaml Platform** extension in VS Code -- or the OCaml
support of the editor you use:

```sh
opam install ocaml-lsp-server
```

Next: [your first app](tutorial/first-app.md).
