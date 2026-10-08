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
- `Cookie.make` defaults to `Path=/; HttpOnly; SameSite=Lax`, and lasts the
  browser's session unless you give `~max_age` (seconds).
  `Cookie.clear` removes one.
- **Spindle decides `Secure`:** on every host but a loopback one, where Safari
  would drop it over plain http.
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
      Spindle.Cookie.encrypted keys ~max_age:(30 * 86400) "prefs" prefs_codec
    and who = Spindle.Cookie.signed keys "who" Spindle.Codec.string in
    ...
| Error sentence -> ...
```

- `Key.of_secret` answers `Error` for a secret under 32 bytes. Read the
  secret yourself, at startup.
- **Rotating a key:** `Key.ring newest retired` signs with `newest` and reads
  with any, so put the new key first and the old one after it.
- **A cookie that fails its signature, its seal or its age is absent**
  (`None`), never an error.
- `~max_age` is checked by the server too, not only sent as `Max-Age`, so a
  copied cookie stops working when it expires.
- `Key.sign`/`Key.verify` and `Key.seal`/`Key.unseal` do the same for
  anything else, such as a token in a link.

## Sessions

`Spindle.Session` keeps a visit's data on the server; its cookie holds only
a random id.

```ocaml
let sessions =
  Spindle.Session.create ~store:(Spindle.Session.memory ())
    ~idle_s:(14 * 86400) ~absolute_s:(90 * 86400) visit_json

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
| `sweep` | deletes every expired session, for an `Alarm` to run |

- A session ends `idle_s` seconds after it was last used, or `absolute_s`
  after it began, whichever is first. The cookie is named `session` unless
  you pass `~cookie`.
- `Session.memory ()` lives in one process and ends with it.
  `Spindle_postgres.Session.store pool ~table` keeps sessions in your
  database ([pool settings](../tutorial/database.md#pool-settings)).

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
    `Access-Control-Allow-Origin`; an origin you did not allow is told
    nothing. An allowed origin also passes the forgery check. `~routes`
    narrows the policy to some routes, say your API. `Any` with
    `~credentials:true` raises.
