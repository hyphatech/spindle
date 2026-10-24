---
title: OAuth bearer tokens
---

Protect routes with OAuth 2.0 access tokens that an authorization server
elsewhere issues -- Auth0, Okta, WorkOS, your company's. Spindle is the
*resource server*: it checks each token and never issues one.

```ocaml
--8<-- "oauth.ml:auth"
```

`issuer` is the authorization server's identifier, exactly as its tokens
write it in `iss`. `resource` is your server's own URL, which a token must
have been issued for. Both are `https` URLs with no query or fragment;
anything else raises `Invalid_argument` where you wrote it.

## Reading the token

```ocaml
--8<-- "oauth.ml:routes"
```

- `Bearer.claims auth` is the checked token: `subject`, `client_id`,
  `scopes`, `expires`, `issued`, `token_id`, and `payload`, every claim, for
  one of your own.
- `Bearer.scope auth "notes:read"` refuses a token that does not grant that
  scope.
- Both are credentials, so the [document](/spindle/tutorial/openapi/) lists
  the `bearer` scheme and each route's scopes.

A token is a JWT access token as [RFC 9068](https://www.rfc-editor.org/rfc/rfc9068)
defines it, and every check that RFC names is made:

- its signature, by RS256, ES256 or EdDSA, under one of the issuer's keys --
  never `none`, and never an HMAC;
- its header's `typ` is `at+jwt`, so an ID token cannot be spent as an
  access token. An issuer that leaves it out is not one these tokens can
  come from: Spindle follows the RFC, not what other servers tolerate;
- `iss` is the issuer, `aud` names your resource, `exp` is still ahead and
  `nbf` passed;
- `sub`, `client_id`, `iat` and `jti` are present.

The token is read from the `Authorization` header and nowhere else: one in a
query string would be in every log it passed. No token, and nothing of its
claims, is logged; a refusal's log line says which check failed.

## What a client is told

A request with no token is a `401` whose challenge says where to read about
getting one:

```console
$ curl -i localhost:8080/notes
HTTP/1.1 401 Unauthorized
www-authenticate: Bearer resource_metadata="https://notes.example.com/.well-known/oauth-protected-resource"
...

{"error":"token_required","message":"A bearer token is needed."}
```

| Code | Status | When |
|---|---|---|
| `token_required` | `401` | No bearer token, or another scheme |
| `invalid_request` | `400` | A malformed `Authorization` header |
| `invalid_token` | `401` | A token that fails any check |
| `insufficient_scope` | `403` | A token without the route's scope; the challenge names it |

The metadata document ([RFC 9728](https://www.rfc-editor.org/rfc/rfc9728))
names your issuer and every scope your routes read, so a client that has
never seen your server can find where to get a token:

```console
$ curl localhost:8080/.well-known/oauth-protected-resource
{"resource":"https://notes.example.com","authorization_servers":["https://id.example.com"],"scopes_supported":["notes:read"],"bearer_methods_supported":["header"]}
```

It is served at `/.well-known/oauth-protected-resource`, followed by your
resource's path if it has one: `https://api.example.com/mcp`'s is at
`/.well-known/oauth-protected-resource/mcp`.

## The issuer's keys

```ocaml
--8<-- "oauth.ml:serve"
```

`Spindle_client.Oauth.keys` finds the issuer's metadata at its well-known
URL ([RFC 8414](https://www.rfc-editor.org/rfc/rfc8414), then OpenID Connect
Discovery), checks it names the issuer, and fetches its keys when a token
first needs them. A token naming a key it has not seen fetches them again,
at most once a minute, so a key the issuer rotates in is picked up. A fetch
that fails is a `warn` line, and tokens are refused until one succeeds.

## Signing in, as a client

The other side: a program that calls a protected resource, and signs a
person in to get its token. `Spindle_client.Oauth` does what MCP's
authorization asks of a client, with no framework:

```ocaml
let oauth =
  Spindle_client.Oauth.create client
    ~clock:(Eio.Stdenv.clock env)
    ~metadata_document:"https://app.example.com/oauth/client.json"
    ~authorize:(fun url -> open_in_browser url)

let token =
  Spindle_client.Oauth.sign_in oauth ~resource:"https://notes.example.com" ()
```

- It reads the resource's metadata ([RFC 9728](https://www.rfc-editor.org/rfc/rfc9728))
  and uses it only where it names that resource, then the authorization
  server's, used only where it names that issuer.
- It identifies itself by an id registered with that server
  (`~registered`), or else by the URL of its
  [Client ID Metadata Document](https://datatracker.ietf.org/doc/draft-ietf-oauth-client-id-metadata-document/),
  where the server reads them.
- `~authorize` is handed the URL a person signs in at, to open in their
  browser, which is sent back to `http://127.0.0.1:<port>/callback`, a
  port the system gives. The answer is checked to be this sign-in's
  (`state`) and the server's own (`iss`,
  [RFC 9207](https://www.rfc-editor.org/rfc/rfc9207)) before its code is
  redeemed, with PKCE by `S256` and the `resource` named
  ([RFC 8707](https://www.rfc-editor.org/rfc/rfc8707)).
- Tokens are kept in `~store`, by resource -- `Oauth.in_memory ()` unless
  given; a keychain or a file of the program's own otherwise -- and
  `Oauth.access` refreshes one as it expires.

An [MCP client](/spindle/guide/mcp/#calling-another-servers-tools) given
`~oauth` does all of this by itself: a `401` signs in, and a `403` for a
scope steps up to it, keeping those granted.

## Testing

A test gives its own keys instead, and signs its own tokens with them:

```ocaml
let app =
  Spindle.Test.app
    ~resources:
      [ Spindle.Dep.resource (Spindle.Bearer.keys auth) (fun ~kid:_ -> [ key ]) ]
    routes
```

`key` is a `Spindle_http.Jwk.t`, read from its JSON with
`Spindle_http.Jwk.of_string`.
