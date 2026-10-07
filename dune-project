(lang dune 3.18)
(name spindle)

; Generated opam files: each package's dependencies are stated here and
; nowhere else.

(generate_opam_files true)

; mlx, OCaml with JSX in it, for the example of a page written in JSX.

(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (preprocess
   (run mlx-pp %{input-file}))))

(maintainers "Hypha Technologies Ltd <dev@hyphatech.io>")

(authors "Hypha Technologies Ltd")

(license MIT)

(maintenance_intent "(latest)")

(source
 (github hyphatech/spindle))

(package
 (name spindle)
 (synopsis "The Eio-native web framework for modern OCaml")
 (description
  "Routes as values, dependencies that list what a route reads, failures as values, streams and WebSockets, the API described as OpenAPI and zod, and HTTP/1.1 read and written by itself. spindle.client calls other servers and links no framework.")
 (depends
  (ocaml
   (>= 5.4))
  (wiretype
   (>= 0.1.0))
  ; The deriver every application describes its JSON with, installed with
  ; the framework so one package is the whole of starting; no library here
  ; links it.
  (ppx_wiretype
   (>= 0.1.0))
  (eio
   (>= 1.5))
  (eio_main
   (>= 1.5))
  (uri
   (>= 4.4.0))
  (angstrom
   (>= 0.16.1))
  (logs
   (>= 0.10.0))
  (mtime
   (>= 2.1.0))
  (cstruct
   (>= 6.2.0))
  (optint
   (>= 0.3.0))
  (digestif
   (>= 1.3.1))
  (base64
   (>= 3.5.2))
  (ipaddr
   (>= 5.6.2))
  (domain-name
   (>= 0.5.0))
  (tls-eio
   (>= 2.1.2))
  (iomux
   (>= 0.4))
  (x509
   (>= 1.1.1))
  (ca-certs
   (>= 1.0.3))
  (mirage-crypto
   (>= 2.4.1))
  (decompress
   (>= 1.6.0))
  (checkseum
   (>= 0.5.3))
  (mirage-crypto-rng
   (>= 2.4.1))
  (odoc
   (and
    :with-dev-setup
    (>= 3.2.1)))
  (merlin
   (and
    :with-dev-setup
    (>= 5.6-504)))
  (ocaml-lsp-server
   (and
    :with-dev-setup
    (>= 1.24.0)))
  (ocamlformat
   (and
    :with-dev-setup
    (= 0.29.0)))
  ; The renderers the page examples are written with: a page is a string
  ; to Spindle, so none of them is a dependency of the framework.
  (htmlit
   (and
    :with-dev-setup
    (>= 0.2.0)))
  (tyxml
   (and
    :with-dev-setup
    (>= 5.0.0)))
  (tyxml-ppx
   (and
    :with-dev-setup
    (>= 5.0.0)))
  (html_of_jsx
   (and
    :with-dev-setup
    (>= 0.1.0)))
  (mlx
   (and
    :with-dev-setup
    (>= 0.11)))
  (jingoo
   (and
    :with-dev-setup
    (>= 1.5.4)))))

(package
 (name spindle_postgres)
 (synopsis "Postgres for a Spindle server: bounded connections, a pool and its probe, and a failure's refusal")
 (depends
  (ocaml
   (>= 5.4))
  (spindle
   (= :version))
  (rowtype
   (>= 0.2.0))
  (rowtype-postgres
   (>= 0.2.0))
  (ptime
   (>= 1.2.0))
  (eio
   (>= 1.5))
  (logs
   (>= 0.10.0))
  ; The suites are this package's, since they reach every library.
  (spindle_cli
   (and
    :with-test
    (= :version)))
  (alcotest
   (and
    :with-test
    (>= 1.9.1)))
  (qcheck-core
   (and
    :with-test
    (>= 0.91)))
  (qcheck-alcotest
   (and
    :with-test
    (>= 0.91)))
  (fmt
   (and
    :with-test
    (>= 0.11.0)))
  ; The reader that is not ours, reading back what wiretype writes.
  (yojson
   (and
    :with-test
    (>= 3.0.0)))
  ; The HTTP suite's referee: a second parser, to disagree with ours.
  (httpun
   (and
    :with-test
    (>= 0.2.0)))
  (tls
   (and
    :with-test
    (>= 2.1.2)))
  ; The client's TLS rows make a certificate, as x509 1.2 names its parts.
  (x509
   (and
    :with-test
    (>= 1.2.0)))))

(package
 (name spindle_cli)
 (synopsis "An application's command line: its API, described from the routes")
 (depends
  (ocaml
   (>= 5.4))
  (spindle
   (= :version))
  (cmdliner
   (>= 2.1.1))
  (eio
   (>= 1.5))
  (eio_main
   (>= 1.5))))
