(lang dune 3.18)
(name spindle)

(using melange 0.1)

(implicit_transitive_deps false)

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
 (name spindle-http)
 (synopsis "HTTP/1.1 as both ends speak it, on Eio: heads, bodies, fields, WebSockets")
 (description
  "What Spindle's server and its client share: a message read off a connection and written to one, every framing RFC 9112 allows, the fields RFC 9110 gives a structure, Structured Fields, multipart and WebSockets. It holds no socket and applies no limit it is not given.")
 (depends
  (ocaml
   (>= 5.5))
  (wiretype
   (and (>= 0.6.0) (< 0.7.0)))
  (eio
   (>= 1.6))
  (angstrom
   (>= 0.16.1))
  (logs
   (>= 0.10.0))
  (mtime
   (>= 2.1.0))
  (ptime
   (>= 1.2.0))
  (digestif
   (>= 1.3.1))
  (base64
   (>= 3.5.2))
  (ipaddr
   (>= 5.6.2))
  ; A JWS's signature checked: RS256, ES256 and EdDSA.
  (mirage-crypto-pk
   (>= 2.4.1))
  (mirage-crypto-ec
   (>= 2.4.1))))

(package
 (name spindle-client)
 (synopsis "Calling other servers from Eio, over HTTPS, with no web framework")
 (description
  "Calls, streamed bodies, Server-Sent Events and WebSockets, over HTTPS with the system's trust store, a switch and a deadline per call, on spindle-http alone.")
 (depends
  (ocaml
   (>= 5.5))
  (spindle-http
   (= :version))
  (wiretype
   (and (>= 0.6.0) (< 0.7.0)))
  (eio
   (>= 1.6))
  (cstruct
   (>= 6.2.0))
  (iomux
   (>= 0.4))
  (mtime
   (>= 2.1.0))
  (ptime
   (>= 1.2.0))
  (uri
   (>= 4.4.0))
  (tls
   (>= 2.1.2))
  (tls-eio
   (>= 2.1.2))
  (x509
   (>= 1.1.1))
  (ipaddr
   (>= 5.6.2))
  (ca-certs
   (>= 1.0.3))
  (mirage-crypto-rng
   (>= 2.4.1))
  (base64
   (>= 3.5.2))
  (domain-name
   (>= 0.5.0))
  (digestif
   (>= 1.3.1))
  (logs
   (>= 0.10.0))))

(package
 (name spindle)
 (synopsis "The Eio-native web framework for modern OCaml")
 (description
  "Routes as values, dependencies that list what a route reads, failures as values, streams and WebSockets, the API described as OpenAPI and Zod, and HTTP/1.1 read and written by itself.")
 (depends
  (ocaml
   (>= 5.5))
  (spindle-http
   (= :version))
  ; The client, installed with the framework so one package is the whole of
  ; starting; the framework never links it, so a server that calls nobody
  ; compiles no TLS.
  (spindle-client
   (= :version))
  (wiretype
   (and (>= 0.6.0) (< 0.7.0)))
  ; A UUID is Uuidm's, in a path or a query as in a body and a row.
  (uuidm
   (>= 0.9.10))
  ; The deriver every application describes its JSON with, installed with
  ; the framework so one package is the whole of starting; no library here
  ; links it.
  (ppx_wiretype
   (and (>= 0.6.0) (< 0.7.0)))
  (eio
   (>= 1.6))
  (eio_main
   (>= 1.6))
  (uri
   (>= 4.4.0))
  (logs
   (>= 0.10.0))
  (mtime
   (>= 2.1.0))
  (ptime
   (>= 1.2.0))
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
  (mirage-crypto
   (>= 2.4.1))
  (decompress
   (>= 1.6.0))
  (checkseum
   (>= 0.5.3))
  (mirage-crypto-rng
   (>= 2.4.1))
  (alcotest
   (and
    :with-test
    (>= 1.9.1)))
  ; The printed client's suite compiles it, as a browser's build would.
  (melange
   (and
    :with-test
    (>= 7.0.1-55)))
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
    (>= 1.25.0)))
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
 (name spindle-mcp-client)
 (synopsis "Calling another server's tools over the Model Context Protocol, with no framework")
 (description
  "MCP 2026-07-28 over HTTP on spindle-client alone: server/discover, tools/list and tools/call, typed by Wiretype descriptions or as plain JSON, a server's questions answered through a function. Its protocol library, spindle-mcp-client.protocol, is MCP's messages, which spindle-mcp's server is built on too.")
 (depends
  (ocaml
   (>= 5.5))
  (spindle-client
   (= :version))
  (spindle-http
   (= :version))
  (wiretype
   (and (>= 0.6.0) (< 0.7.0)))
  (base64
   (>= 3.5.2))
  (logs
   (>= 0.10.0))))

(package
 (name spindle-mcp)
 (synopsis "A Model Context Protocol server: the routes an agent calls tools through")
 (description
  "MCP 2026-07-28 over Streamable HTTP, as routes added to a Spindle application's own: server/discover, tools/list and tools/call, each tool a name, its arguments' and its result's descriptions, and a dependency giving its function.")
 (depends
  (ocaml
   (>= 5.5))
  (spindle
   (= :version))
  (spindle-http
   (= :version))
  (spindle-mcp-client
   (= :version))
  (wiretype
   (and (>= 0.6.0) (< 0.7.0)))
  (ptime
   (>= 1.2.0))
  (base64
   (>= 3.5.2))))

(package
 (name spindle-postgres)
 (synopsis "Postgres for a Spindle server: bounded connections, a pool and its probe, and a failure's refusal")
 (depends
  (ocaml
   (>= 5.5))
  (spindle
   (= :version))
  (rowtype
   (and (>= 0.9.0) (< 0.10.0)))
  (rowtype-postgres
   (and (>= 0.9.0) (< 0.10.0)))
  (ptime
   (>= 1.2.0))
  (mtime
   (>= 2.1.0))
  (eio
   (>= 1.6))
  (logs
   (>= 0.10.0))
  ; The suites are this package's, since they reach every library.
  (spindle-cli
   (and
    :with-test
    (= :version)))
  (spindle-mcp
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
  (eio_main
   (and
    :with-test
    (>= 1.6)))
  (wiretype
   (and
    :with-test
    (>= 0.6.0)
    (< 0.7.0)))
  (uri
   (and
    :with-test
    (>= 4.4.0)))
  (angstrom
   (and
    :with-test
    (>= 0.16.1)))
  (ipaddr
   (and
    :with-test
    (>= 5.6.2)))
  (cstruct
   (and
    :with-test
    (>= 6.3.0)))
  (base64
   (and
    :with-test
    (>= 3.5.2)))
  (decompress
   (and
    :with-test
    (>= 1.6.0)))
  (mirage-crypto-rng
   (and
    :with-test
    (>= 2.4.1)))
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
  (tls-eio
   (and
    :with-test
    (>= 2.1.2)))
  ; The client's TLS rows make a certificate, as x509 1.2 names its parts.
  (x509
   (and
    :with-test
    (>= 1.2.0)))
  ; The OAuth rows sign what the server checks.
  (mirage-crypto-ec
   (and
    :with-test
    (>= 2.4.1)))
  (digestif
   (and
    :with-test
    (>= 1.3.1)))))

(package
 (name spindle-sqlite)
 (synopsis "SQLite for a Spindle server: a pool in WAL mode and its probe, sessions, and a failure's refusal")
 (depends
  (ocaml
   (>= 5.5))
  (spindle
   (= :version))
  (rowtype
   (and (>= 0.9.0) (< 0.10.0)))
  (rowtype-sqlite
   (and (>= 0.9.0) (< 0.10.0)))
  (ptime
   (>= 1.2.0))
  (mtime
   (>= 2.1.0))
  (eio
   (>= 1.6))
  (logs
   (>= 0.10.0))
  (alcotest
   (and
    :with-test
    (>= 1.9.1)))
  (eio_main
   (and
    :with-test
    (>= 1.6)))
  (wiretype
   (and
    :with-test
    (>= 0.6.0)
    (< 0.7.0)))))

(package
 (name spindle-cli)
 (synopsis "An application's command line: its API, described from the routes")
 (depends
  (ocaml
   (>= 5.5))
  (spindle
   (= :version))
  (cmdliner
   (>= 2.1.1))))
