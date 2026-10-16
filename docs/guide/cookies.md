# Cookies, sessions and CORS

Cookies, sessions, and what Spindle checks on a request before your route
runs.

## Reading and setting cookies

Declare a cookie once, by name and codec, and use it to read and to set.
This page counts your visits:

```ocaml
--8<-- "cookie.ml"
```

```sh
curl -i -c jar -b jar localhost:8080/
```

```text
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
set-cookie: visits=1; Path=/; HttpOnly; SameSite=Lax
...

Visit number 1.
```

```sh
curl -c jar -b jar localhost:8080/
```

```text
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
(sealed) over a key ring, then read and set it as any other:

```ocaml
match Spindle.Key.of_secret secret with
| Ok key ->
    let keys = Spindle.Key.ring key [] in
    let prefs =
      Spindle.Cookie.encrypted keys ~max_age:Mtime.Span.(30 * day) "prefs" prefs_codec
    and who =
      Spindle.Cookie.signed keys ~max_age:Mtime.Span.(8 * hour) "who" Spindle.Codec.string
    in
    ...
| Error sentence -> ...
```

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
  anything else, such as a token in a link. They use keys derived apart
  from the cookies' keys, so nothing you sign or seal with them can ever be
  passed off as a cookie.

## Sessions

`Spindle.Session` keeps a visit's data on the server; its cookie holds only
a random id.

```ocaml
let sessions =
  Spindle.Session.create ~store:(Spindle.Session.memory ())
    ~idle:Mtime.Span.(14 * day) ~absolute:Mtime.Span.(90 * day) visit_json

(let+ session = Spindle.Session.cookie sessions
 and+ set_cookie = Spindle.set_cookie
 and+ now = Spindle.now in
 match Spindle.Session.find sessions session ~now with ...)
```

| Call | What it does |
|---|---|
| `find` | the session, if it exists and is within both limits |
| `start` | a new session, and its cookie |
| `update` | new data under the same id |
| `renew` | a new id with this data, the old one deleted: call it at sign-in |
| `close` | deletes it and clears the cookie: sign-out |
| `sweep` | deletes every expired session; run it periodically (see below) |

Signing in gives the visitor a new session id, whether or not they had a
session before, so an id somebody planted earlier signs them into nothing.
Signing out deletes the session on the server:

```ocaml
let sign_in sessions id ~set_cookie ~now user =
  let started =
    match Spindle.Session.find sessions id ~now with
    | Ok (Some session) ->
        Spindle.Session.renew sessions session ~set_cookie ~now { user }
    | Ok None -> Spindle.Session.start sessions ~set_cookie ~now { user }
    | Error e -> Error e
  in
  match started with
  | Ok _ -> Ok "Signed in."
  | Error e -> Error (Spindle.Session.refusal e)

let sign_out sessions id ~set_cookie ~now =
  match Spindle.Session.find sessions id ~now with
  | Ok None -> Ok "Signed out."
  | Ok (Some session) -> (
      match Spindle.Session.close sessions session ~set_cookie with
      | Ok () -> Ok "Signed out."
      | Error e -> Error (Spindle.Session.refusal e))
  | Error e -> Error (Spindle.Session.refusal e)
```

`Session.data session` is the data a found session holds. A store that
fails is `Error`; `Session.refusal` turns it into a `500` whose detail goes
to the log.

- A session ends `idle` after it was last used, or `absolute` after it
  began, whichever comes first. Both are `Mtime.Span.t`s; pass `~now` from
  the `Spindle.now` dependency. The cookie is named `session` unless you
  pass `~cookie`, and its `Max-Age` is `absolute`, rounded up to whole
  seconds.
- `sweep` deletes the sessions nobody came back to, which `find` never sees.
  Run it every so often from a [background fiber](background.md).
- `Session.memory ()` lives in one process and ends with it.
  `Spindle_postgres.Session.store pool ~table` keeps sessions in your
  database. The table must exist first: create it in a migration of your
  own from the SQL that `Spindle_postgres.Session.schema ~table` gives
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
