# Requests, cookies and sessions

- `Spindle.Cookie.make` defaults to `HttpOnly; SameSite=Lax`, and **`Secure`
  is not the handler's decision**: it is set on every host but a loopback one,
  because Safari silently drops a `Secure` cookie over plain http.
  `https` from a trusted proxy's forwarding header wins.
- **A cookie holds what a cookie can hold.** `Cookie.named` raises
  `Invalid_argument` on a name that is not a token, and `Cookie.make` on a
  value its codec prints with a space, quote, comma, semicolon or backslash
  in it, any of which could end the cookie early or write an attribute of
  its own -- a cookie's name is a constant written in source, and a token,
  a number or a word of an enum never prints so. Text that arrived at
  runtime is a cookie declared with `Spindle.Cookie.encoded`, which
  base64url-encodes it and cannot fail.
- **A cookie a browser cannot forge** is declared `Cookie.signed` or
  `Cookie.encrypted` over a `Key.ring`, and read and set as any declared
  cookie is:

  ```ocaml
  match Spindle.Key.of_secret secret with
  | Ok key ->
      let keys = Spindle.Key.ring key [] in
      let prefs = Spindle.Cookie.encrypted keys ~max_age:(30 * 86400) "prefs" prefs_codec
      and who = Spindle.Cookie.signed keys "who" Spindle.Codec.string in ...
  | Error sentence -> ...
  ```

  `Key.of_secret` refuses a secret under 32 bytes as a value, the secret
  being the application's to read, and derives two keys from it with
  HKDF-SHA256, one to sign and one to seal; `Key.ring newest retired` makes
  with the first and reads with any, so a key is rotated by putting a new
  one first. A signed value is readable, with an HMAC-SHA256 over the name,
  the second it was made and the value; an encrypted one is sealed with
  AES-256-GCM under a nonce from the operating system's generator, the name
  bound to it -- so neither can be moved to another cookie. **One that fails
  its signature, its seal or its age is absent**, a `debug` line naming it,
  since a browser holding one from a retired key or an old visit did nothing
  wrong. `~max_age` is enforced by the server as well as sent as `Max-Age`,
  because a copied cookie replays for ever, and the stamp is the app's `now`
  as the answer is written, so a test that sets its clock ages a cookie
  without sleeping. `Key.sign` and `Key.seal` do the same for anything else
  that must come back as it was sent.
- `Spindle.client` is the peer, or the hop a *trusted* proxy vouches for
  (`Spindle.Server.run ~trusted_proxies`, each an address or a CIDR range) --
  none by default, because a header a client can write is a rate limit a
  client can step around. `~proxy_header` names the header those proxies
  write: `X_forwarded_for` unless given -- `X-Forwarded-For`,
  `X-Forwarded-Host`, `X-Forwarded-Proto` -- or `Forwarded`, RFC 7239's
  `for`, `host` and `proto`. Only the one named is read, since a proxy that
  writes one and passes the other through from the client would let the
  client choose its own address (`Request.proxied`, `Request.host`). Each is
  read in every line it came in, because a proxy may add a line of its own
  rather than join the client's: the rightmost address the proxy did not
  write -- the peer, where that hop is `unknown` or hidden -- and the host
  and scheme it wrote last. An IPv4 peer reached through the IPv6 wildcard is
  its IPv4 address, so a proxy named by one is trusted through the other.
- **Forgery is refused by default.** A request by any method but `GET`,
  `HEAD` and `OPTIONS` that a browser sent from another site is
  `403 cross_origin`, before any route sees it: `Sec-Fetch-Site` decides
  where a browser sends it, and `Origin` against the request's host where it
  does not. A request with neither is not from a browser and passes, since
  forgery is an attack a browser is made to carry out. `App.make
  ~trusted_origins` names other sites that may, and `~check_origin:false`
  turns it off. `Spindle.json` adds the second half: a body that says it is
  anything but JSON, or whose `Content-Type` is no media type, is `415`,
  because a browser sends `text/plain` or a form from another site without
  asking, and JSON only after a preflight. Its parameters are ignored, as RFC
  8259 §11 has a `charset` on JSON mean nothing.
- **Another site's page calls a route only where the app says** --
  `App.make ~cors:(Spindle.Cors.make ~credentials:true (Origins [ "https://app.example.com" ]))`,
  absent unless given. The framework answers the preflight, on a path a
  covered route answers, with the methods the table has there and the asked
  headers the policy allows, and an origin it does not allow is told
  nothing. Every answer of a covered route says `Vary: Origin`, and one to an
  allowed origin names it -- a middleware's refusal included, so the page
  can read why. A named origin is trusted by the forgery check on the routes
  the policy covers; `Any`, which `Cors.make` refuses beside credentials as
  the Fetch standard does, trusts only a request with no cookie, since a form
  another site posts is never preflighted. `~routes` narrows it to an app's
  API.
- **A trailing slash is another path** -- `404` -- unless `App.make
  ~trailing_slash:Redirect` asks for a `308` to the path without it. `Allow`
  lists `HEAD` wherever it lists `GET`.
- A body is read only when the framing says one is there, and only once the
  dependencies that do not need it have refused nothing; it is not on
  `Request.t`, so only a dependency that says it needs it (`Dep.of_body`)
  ever sees it.

## Sessions

`Spindle.Session` keeps a visit's data on the server, and its cookie holds
only an id:

```ocaml
let sessions =
  Spindle.Session.create ~store:(Spindle.Session.memory ())
    ~idle_s:(14 * 86400) ~absolute_s:(90 * 86400) visit_json

(let+ session = Spindle.Session.cookie sessions
 and+ set_cookie = Spindle.set_cookie and+ now = Spindle.now in
 match Spindle.Session.find sessions session ~now with ...)
```

An id is 128 bits from the operating system's generator, so there is
nothing to sign or guess, and the store keys its SHA-256 digest, so a copy
of the store signs nobody in. `Session.cookie` is a credential -- what the
request carries -- and `find` is the handler's to call, as every read is.
`start` makes one, `update` changes its data under the same id, `renew` at
sign-in gives it a new id and deletes the old, so an id somebody planted
signs them into nothing, and `close` deletes it and clears the cookie, so a
copy of that cookie signs nobody in. It ends by itself at `idle_s` since it
was last used -- moved on only by a `find` that finds a tenth of it spent,
so a busy session is not a write per request -- or `absolute_s` since it
began; data that no longer reads as its description is no session. A store
is a record of functions over a digest: `Session.memory ()` is a table
behind a lock for one process, and `Spindle_postgres.Session.store` a table
of the application's database ([A database](../tutorial/database.md#the-pool)). `Session.sweep` deletes what has
expired, for an `Alarm` to run.

## A cookie, read and set

The page counts your visits:

```ocaml
--8<-- "cookie.ml"
```
