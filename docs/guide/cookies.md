# Cookies, sessions and CORS

Cookies, sessions, and what Spindle checks on a request before your route
runs.

## Reading and setting cookies

Declare a cookie once, by name and codec, and use it to read and to set.
This page counts your visits:

```ocaml
--8<-- "cookie.ml"
```

```console
$ curl -i -c jar -b jar localhost:8080/
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
set-cookie: visits=1; Path=/; HttpOnly; SameSite=Lax
...

Visit number 1.

$ curl -c jar -b jar localhost:8080/
Visit number 2.
```

- `Cookie.optional` reads it (`None` when absent) and `Cookie.required`
  refuses without it. A value that does not parse is `400 invalid` at
  `cookie.<name>`.
- `Cookie.make` defaults to `Path=/; HttpOnly; SameSite=Lax`. A plain
  cookie lasts until the browser closes unless you give `~max_age_s`
  (seconds); a signed or encrypted one is given `Max-Age` from its own
  `~max_age` (below). `Cookie.clear` removes one.
- **Spindle adds `Secure` itself** on every host except a loopback one
  (`localhost`, `127.0.0.1`, `::1`), where Safari would silently drop a
  `Secure` cookie sent over plain http. Behind a proxy that ends TLS, list
  the proxy in `~trusted_proxies` so that its word that the browser used
  `https` is believed ([below](#the-clients-ip-address)).
- **The value must be cookie-safe.** `Cookie.make` raises
  `Invalid_argument` on a value with a space, quote, comma, semicolon,
  backslash or control character. For text that arrived at run time, use
  the `Spindle.Cookie.encoded` codec, which holds any string.

## Signed and encrypted cookies

Declare a cookie `signed` (readable, but tamper-proof) or `encrypted`
(sealed), then read and set it as any other. The keys they are sealed under
are the server's, given where it starts, so the cookies and the routes that
read them are values like any other:

```ocaml
let prefs =
  Spindle.Cookie.encrypted ~max_age:Mtime.Span.(30 * day) "prefs" prefs_codec

let who =
  Spindle.Cookie.signed ~max_age:Mtime.Span.(8 * hour) "who" Spindle.Codec.string

let () =
  match Spindle.Key.of_secret (Sys.getenv "COOKIE_SECRET") with
  | Ok key ->
      Eio_main.run @@ fun env ->
      Spindle.serve env ~keys:(Spindle.Key.ring key []) routes
  | Error sentence -> prerr_endline sentence
```

- **No keys, no start.** A route that reads a signed or encrypted cookie in
  a server given no `~keys` stops it before it listens, naming the route;
  one that only sets such a cookie is answered `500`, logged. A test gives
  its own: `Spindle.Test.app ~keys routes`.
- `Key.of_secret` answers `Error` for a secret under 32 bytes. Read the
  secret yourself, at startup.
- **Rotating a key:** `Key.ring newest retired` signs with `newest` and reads
  with any, so put the new key first and the old one after it.
- **A cookie that fails its signature, its seal or its age is absent**
  (`None`), never an error.
- **`~max_age` is required**, an `Mtime.Span.t`. The server checks it on
  every read, not only the browser, so a copied cookie stops working when it
  expires. `Cookie.make` writes it as `Max-Age`, rounded up to whole
  seconds; passing `~max_age_s` to `make` can make that shorter, never
  longer.
- **A signed or encrypted cookie holds any value its codec prints**, since
  what is sent is encoded as base64url. You need the `encoded` codec only
  for a plain cookie.
- `Key.sign`/`Key.verify` and `Key.seal`/`Key.unseal` do the same for
  anything else, such as a token in a link; a handler reads the server's
  ring as `Spindle.keys`. They use keys derived apart from the cookies'
  keys, so nothing you sign or seal with them can ever be passed off as a
  cookie.

## Sessions

`Spindle.Session` keeps a visit's data on the server; its cookie holds only
a random id. A session is a [dependency](../tutorial/dependencies.md): a
route reads it, and is handed the session its request's cookie names.

```ocaml
--8<-- "session.ml"
```

```console
$ curl -c jar -b jar -X POST localhost:8080/sign-in/kim
Signed in.

$ curl -c jar -b jar localhost:8080/me
You are kim.

$ curl -c jar -b jar -X POST localhost:8080/sign-out
Signed out.

$ curl -c jar -b jar localhost:8080/me
Nobody is signed in.
```

| Call | What it does |
|---|---|
| `get` | the session's data, if its cookie names one within both limits |
| `put` | replaces the data, or starts a session holding it, with its cookie |
| `rotate` | moves the session to a new id, keeping its data: at sign-in |
| `destroy` | deletes the session and clears its cookie: sign-out |

Each answers a `result` whose `Error` is a refusal: a store that fails is a
`500`, its words in the log and none on the wire, so each call goes on with
`let*` beside the handler's own.

- **Sign-in rotates**, so an id somebody planted in the browser before
  signs them into nothing after. `rotate` and `put` end in the same place
  in either order, and `rotate` with no session does nothing.
- **A session is the request's.** Every use of it in one request is the
  same session, so what a `put` wrote a later `get` reads, and the store is
  asked once.
- **A session ends** `idle` after it was last used, or `absolute` after it
  began, whichever comes first, on the request's clock. The cookie is named
  `session` unless you pass `~cookie`, and its `Max-Age` is `absolute`,
  rounded up to whole seconds.
- **Ended sessions are swept for you.** Nobody comes back for a session
  that ended, so the first request to read one ten minutes after the last
  sweep deletes a batch of them, and the next request another while there
  are more: the store never fills with old visits, and no request waits on
  more than a batch. Several servers on one database share the work.
- **Where it is kept** is `~store`, a dependency like any other.
  `Session.memory ()` lives in one process and ends with it.
  `Spindle_postgres.Session.store db ~table` keeps sessions in your
  database, read through the pool's
  [resource](../tutorial/dependencies.md#resources):

    ```ocaml
    let session =
      Spindle.Session.create
        ~store:(Spindle_postgres.Session.store db ~table:"sessions")
        ~idle:Mtime.Span.(14 * day)
        ~absolute:Mtime.Span.(90 * day)
        visit_json
    ```

    The table must exist first: create it in a migration of your own from
    the SQL that `Spindle_postgres.Session.schema ~table` gives
    ([pool settings](../tutorial/database.md#pool-settings)).

## The client's IP address

`Spindle.client` is the address of whoever connected. Behind a reverse
proxy, list the proxy in `Spindle.serve ~trusted_proxies` (addresses or
CIDR ranges, such as `10.0.0.0/8`; none by default), and the client is the
address the proxy forwarded for. `~proxy_header` names the header it writes:
`X_forwarded_for` (the default) or `Forwarded`. The same header gives the
host and whether the browser used `https`.

## CSRF and CORS

- **Cross-site writes are refused by default.** A request by any method but
  `GET`, `HEAD` and `OPTIONS` that a browser sent from another site is
  `403 cross_origin`. Requests from curl, apps and other servers pass.
  `~trusted_origins` allows other sites; `~check_origin:false` turns the
  check off.
- **`Spindle.json` accepts only JSON:** a body whose `Content-Type` is not
  `application/json` (or `application/...+json`) is `415`.
- **Another site's page may call your routes only if you allow it:**

    ```ocaml
    Spindle.serve env
      ~cors:
        (Spindle.Cors.make ~credentials:true
           (Spindle.Cors.Origins [ "https://app.example.com" ]))
      routes
    ```

    Spindle answers the preflight itself and names an allowed origin in
    `Access-Control-Allow-Origin`, or answers `*` under `Any`; an origin you
    did not allow is told nothing. An allowed origin also passes the forgery
    check.

    - `~allow_headers` lists the headers a request may send: `authorization`
      and `content-type` unless you say otherwise. A page that sends any
      other header fails the preflight, and the browser says only that the
      request was blocked.
    - `~expose` lists the response headers the page's script may read (none
      by default).
    - `~max_age_s` is how long a browser keeps a preflight's answer (600
      seconds).
    - `~routes` narrows the policy to some routes, say your API.

    `Any` with `~credentials:true` raises. Under `Any`, a write from another site
    passes only with no credential the browser attaches by itself: no
    `Cookie`, and no `Authorization` in a scheme a browser keeps -- `Basic`,
    `Digest`, `Negotiate`, `NTLM`. A token the page sets itself, such as
    `Authorization: Bearer ...`, is served.
