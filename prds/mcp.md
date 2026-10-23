# MCP servers and clients, and the OAuth they need

**Status: Accepted** — the whole shape is signed off; stage 1 has landed.
Date: 2026-10-23

## The problem

Spindle has one way to be called: a REST route, a method and a path. An
agent calls tools through the Model Context Protocol instead, and an
OCaml program can neither offer tools to one nor call another's without
writing JSON-RPC, the protocol's headers and its OAuth by hand. The owner
asked for Spindle to build MCP servers and clients.

MCP's revision of 2026-07-28 makes it a good fit for the first time. The
protocol is now stateless: there is no session and no `initialize`, every
request carries its version and the client's capabilities in `_meta`, and
a server asks the client a question by answering `input_required`, so
that the client retries the request with the answers (*multi round-trip
requests*, MRTR), never by sending a request of its own. Each call is one
POST answered on its own: what a Spindle route already is.

A second need came with it. A program that calls other servers can link
`spindle.client` without the framework, but cannot install it without
the framework, since it ships in the `spindle` package: an Eio program
that wants only the client installs a web framework, and an MCP client
would too.

## Scope

It covers, in this repository alone:

- the client and HTTP installed without the framework: packages
  `spindle-http` and `spindle-client`;
- an OAuth 2.1 resource server in `spindle`: bearer tokens validated,
  challenged and described, as any route may use them, MCP or REST;
- an OAuth 2.1 client in `spindle-client`: finding the authorization
  server, authorizing a person in their browser and keeping their tokens;
- an MCP server, `spindle-mcp`, over Streamable HTTP: `server/discover`, tools, resources, prompts, progress, cancellation,
  elicitation by MRTR and `subscriptions/listen`;
- an MCP client, `spindle-mcp-client`, over Streamable HTTP.

It does not cover:

- **any protocol version before 2026-07-28.** No `initialize`, no
  `Mcp-Session-Id`, no GET stream, no HTTP+SSE transport. We are building
  a new ecosystem; a legacy client is answered with the version we speak.
- **what MCP deprecates in 2026-07-28**: sampling, roots, logging and
  Dynamic Client Registration (RFC 7591). The deprecation policy says new
  implementations should not add them.
- **being an authorization server.** Logging a person in, consenting and
  issuing tokens are a product of their own; an application uses Keycloak,
  Auth0, WorkOS or its company's. MCP leaves it out of scope too.
- **the tasks extension** (`io.modelcontextprotocol/tasks`), which may follow
  once the core has landed.
- **JSON-RPC as an interface of its own.** It is MCP's envelope here, not a
  third kind of endpoint beside REST and WebSockets (*Design*).
- **the stdio transport**, server or client. Spindle is a web framework,
  and so an HTTP one: what it is for -- routes, dependencies, the server's
  limits, OAuth, traces -- is HTTP's, and a server on the person's own
  machine is reached over HTTP on `localhost` as well, which every MCP
  client speaks. The client's side, starting another program's stdio
  server, may follow if a user asks; nothing here assumes a tool is
  reached one way.

## User scenarios

1. **A tool in five lines.** A developer with a Spindle application adds a
   tool that reads its arguments, a database pool and the signed-in user,
   serves it at `/mcp`, and Claude Code calls it. *Accepted when* the
   official TypeScript SDK's client lists the tool with the input and
   output schemas the descriptions print, calls it and reads its
   `structuredContent`.
2. **A tool behind OAuth.** The same server is given an issuer and its
   canonical URI. *Accepted when* a call without a token is answered `401`
   with `WWW-Authenticate: Bearer resource_metadata=...`, the metadata
   document names the issuer, a token from that issuer for another
   audience is answered `401`, and a token without a tool's scope `403`
   with `error="insufficient_scope"` and that scope.
3. **A question in the middle of a tool.** A tool that deletes asks the
   person to confirm. *Accepted when* the first call answers
   `input_required` with one `elicitation/create`, the retry with
   `accept` runs the tool once, `decline` runs it with the refusal in
   hand, and a client that declared no `elicitation` is answered `-32021`.
4. **Progress and cancellation.** A slow tool reports progress. *Accepted
   when* a call with a `progressToken` is answered as an event stream of
   `notifications/progress` ending in the result, one without as one JSON
   object, and closing the stream resolves the handler's
   `Spindle.client_gone`.
5. **Calling another server's tools.** An OCaml program that installed
   only `spindle-mcp-client` lists and calls a remote server's tools,
   typed by Wiretype descriptions or as plain JSON. *Accepted when* it
   calls the TypeScript SDK's reference server, answers its elicitation
   through a function it was given, and installs neither `spindle` nor
   `spindle-mcp`.
6. **A person signs in once.** The client calls a server that answers
   `401`. *Accepted when* it finds the authorization server from the
   resource's metadata, opens the browser for the person with PKCE and
   the `resource` parameter, catches the redirect on loopback, refuses one
   whose `iss` differs, retries the call with the token, refreshes it
   before it expires, and on `insufficient_scope` asks again for the union
   of its scopes and the challenge's.
7. **Only the client.** An Eio program installs `spindle-client` alone.
   *Accepted when* `opam install spindle-client` installs neither
   `spindle` nor `ppx_wiretype`, and the program calls an HTTPS server.

## Requirements

- **FR-1.** `spindle-http` and `spindle-client` install and link without
  the framework; `spindle` depends on both.
- **FR-2.** A route, MCP or REST, may require a bearer token validated
  locally as an RFC 9068 JWT against its issuer's keys, refused `401`
  for an invalid, expired or foreign token and for one for another
  audience (RFC 8707), and `403` with `insufficient_scope` for a missing
  scope (RFC 6750 §3.1); every refusal carries its challenge.
- **FR-3.** A server that requires a bearer token serves its RFC 9728
  metadata document at the well-known path its resource's URI gives, its
  `scopes_supported` the scopes its routes read.
- **FR-4.** A tool is one value: its name, what it reads -- arguments,
  resources, credentials, as any dependency -- and what it returns; its
  input and output schemas are printed from the descriptions it reads and
  returns, and nothing else states them.
- **FR-5.** The MCP endpoint answers 2026-07-28 and nothing else: it
  validates `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` against
  the body, the required `_meta`, the `Origin`, and the client's
  capabilities, each with the status and JSON-RPC error the
  specification names.
- **FR-6.** Arguments that do not read, and a refusal the application
  makes, answer a tool execution error (`isError`) the model can read; a
  malformed request, an unknown tool and the server's own bug answer a
  JSON-RPC error that leaks nothing.
- **FR-7.** A tool, resource or prompt may ask the client for input by
  MRTR, every question it reads asked in one round; a state the server
  keeps across rounds is sealed, bound to the caller, the call and an
  expiry, and one that does not read is absent.
- **FR-8.** A tool may report progress, answered as an event stream only
  when the client asked for it; a closed stream is `Spindle.client_gone`.
- **FR-9.** Resources, resource templates and prompts are values like
  tools; list results carry `ttlMs` and `cacheScope`, `private` wherever
  the endpoint reads a credential.
- **FR-10.** `subscriptions/listen` delivers the change notifications a
  client opted into, fed from a `Broadcast`.
- **FR-11.** The MCP client calls, lists, retries MRTR rounds through
  functions it is given, reports progress, mirrors `x-mcp-header`
  arguments, and links no framework.
- **FR-12.** The OAuth client discovers (RFC 9728, RFC 8414, OpenID
  Connect Discovery), identifies itself by a Client ID Metadata Document
  or a pre-registered id, authorizes with PKCE `S256` and `resource`
  (RFC 7636, RFC 8707), checks `iss` (RFC 9207), refreshes, keys what it
  keeps by issuer, and steps up on `insufficient_scope`.

## Design

### Packages

| Package | Libraries | Links |
|---|---|---|
| `spindle-http` | `spindle-http` | Eio, Wiretype, the HTTP and JWS it reads |
| `spindle-client` | `spindle-client` | `spindle-http`, TLS |
| `spindle` | `spindle` | `spindle-http` -- never `spindle-client` |
| `spindle-mcp-client` | `spindle-mcp-client`, `spindle-mcp-client.protocol` | `spindle-client`; the protocol library Wiretype alone |
| `spindle-mcp` | `spindle-mcp` | `spindle`, `spindle-mcp-client.protocol` |

`spindle.http` and `spindle.client` are renamed by the split -- dune names a
package's libraries after it -- which is a change every caller's `dune`
makes once, before 1.0. The protocol library holds JSON-RPC 2.0 as MCP
uses it and every message of 2026-07-28 as a Wiretype description, so
the server and the client cannot read one message two ways, and it
links no I/O.

They stay in this repository, released together at one version, as
`spindle-postgres` and `spindle-sqlite` are.

*Rejected:* one `spindle-mcp` package with a client sub-library, which
installs the framework for a client; keeping the client in `spindle`,
which is what scenario 7 is about; and a repository of its own for the
HTTP client, as Wiretype and Rowtype have, which pays for a release
cadence and users outside Hypha Stack that the client does not have.

### A tool is a route's twin

```ocaml
module Mcp = Spindle_mcp

let forecast =
  Mcp.tool "get_forecast" ~title:"Forecast"
    ~doc:"The weather for a city, a day at a time."
    (Mcp.Returns.json forecast_json)
    (let+ q = Mcp.arguments query_json
     and+ db = Db.pool
     and+ () = Spindle.Bearer.scope auth "weather:read" in
     Forecast.find db q)

let () =
  Eio_main.run @@ fun env ->
  Spindle.serve env ~resources:[ ... ]
    (Mcp.routes Path.(s "mcp") ~name:"weather" ~version:"1.0.0"
       ~tools:[ forecast ] ())
```

A tool's arguments are a dependency, `Mcp.arguments`, as a path parameter
is `Spindle.param`, so *A route is one value, and a dependency hands over
an input* holds for a tool unchanged: what it reads is listed, its
`inputSchema` is the description its `Mcp.arguments` reads (Wiretype
prints JSON Schema 2020-12 already), and a tool that reads two is refused
when the routes are made. Everything a route may read, a tool may: a
resource, the bearer's claims, a rate limit, `Spindle.now`.

`Mcp.routes` is ordinary routes: one `POST` at the path, and the
metadata document when a credential is read. They get the server's
limits, deadlines, logging and traces. A GET or DELETE is the router's
`405` already, as 2026-07-28 asks of a server that speaks only it.

`tools/list` names only the tools the caller's token may call, as MCP
allows: a tool's scopes are known without running it, so the list is
filtered without a call, a model is never shown a tool that would only
answer `403`, and a caller learns nothing of tools beyond their grant. A
scope a tool asks for from its arguments, inside a `Dep.bind`, is still
challenged with `insufficient_scope` when called, which is where a
client steps up. *Rejected:* every tool for every caller, which keeps
step-up for any tool but lets a model plan with tools that fail.

`Mcp.Returns.json` is `outputSchema`, `structuredContent` and the text
the specification asks beside it; `Mcp.Returns.text` and
`Mcp.Returns.content` are unstructured content. A handler returns
`('a, Refusal.t) result`, as a route does, so dependencies compose
across both. Where an answer goes:

| What happened | Answered |
|---|---|
| Arguments that do not read | `isError`, every problem named |
| A refusal of the application's | `isError`, its sentence |
| A bearer refusal | HTTP `401` or `403`, its challenge, a JSON-RPC error |
| A rate limit | HTTP `429`, `Retry-After` |
| Unreadable JSON, a batch, a null id | HTTP `400`, `-32700` or `-32600` |
| An unknown tool | `-32602` |
| Headers that disagree with the body | HTTP `400`, `-32020` |
| A question for a capability not declared | HTTP `400`, `-32021` |
| A version other than 2026-07-28 | HTTP `400`, `-32022`, `supported` |
| A bug | `-32603`, nothing of the exception |

*Rejected:* a tool as a function from its arguments to a dependency,
`fun args -> ...`. It reads naturally but makes every dependency inside
it at each call, so a tool's scopes, codes and resources cannot be
listed, which the metadata document's `scopes_supported` and the start's
check of resources need. *Rejected:* a tool as a `Route.t` of a pseudo
method, which would put tools in the OpenAPI document and their
arguments where a body is described.

### Questions by MRTR

```ocaml
let confirm =
  Mcp.Input.elicit "confirm" ~message:"Delete the folder and all it holds?"
    confirm_json

let delete =
  Mcp.tool "delete_folder" Mcp.Returns.text
    (let+ folder = Mcp.arguments folder_json and+ answer = confirm in
     match answer with
     | Accept _ -> Folder.delete folder
     | Decline | Cancel -> Ok "Nothing was deleted.")
```

`Mcp.Input.elicit` is a dependency: answered when the retry carries a
response under its key, read by its description; otherwise it stops the
tool before its handler, as a refusal does. Every unanswered question a
tool reads is collected, as invalid inputs are, so they are asked in one
round. A client that did not declare `elicitation` is answered `-32021`
before anything runs. A question computed from what was read is
`Mcp.Input.ask`, inside a `Dep.bind`.

A tool that reads no state sends no `requestState`: the client re-sends
the arguments, and an elicitation's answer is the person's own input,
which nothing on the server needs to vouch for. A tool that keeps state
across rounds reads `Mcp.Input.state desc`, sealed with the
application's key ring as an encrypted cookie is, bound to the caller's
subject, the method, the tool, a digest of the arguments and an expiry
from `now`; one that fails any of them is absent and the question is
asked again, never an error.

*Rejected:* sealing a state on every round, which costs a key ring every
MCP server must configure, to protect nothing a tool reads.

### Bearer tokens, in `spindle`

```ocaml
let auth =
  Spindle.Bearer.make ~issuer:"https://id.example.com"
    ~resource:"https://mcp.example.com/mcp" ()

let user = Spindle.Bearer.claims auth            (* a credential *)
let writes = Spindle.Bearer.scope auth "files:write"
```

`Bearer.claims` is a `Dep.credential` reading `Authorization`, with
`Auth.credentials`; it verifies the JWS (RS256, ES256 and EdDSA, never
`none` or an HMAC), then RFC 9068: `typ`, `iss`, `aud` against the
resource's canonical URI, `exp` and `nbf` from `Spindle.now`, `scope`.
A token whose `typ` is not `at+jwt` is refused, as RFC 9068 §4 asks,
whatever issuer made it, with no argument to accept one: Spindle follows
the RFC, not what other implementations tolerate, and the check is what
keeps an ID token from being spent as an access token.
The keys are a resource, `Bearer.keys auth`, which the program supplies
when it starts: `spindle` never links the client, since that would link
TLS into every application, as `client/dune` says. `Spindle_client.Oauth.keys`
fetches them from the issuer's metadata's `jwks_uri` and fetches again on
an unknown `kid`, at most once a minute. `Spindle.Bearer.metadata auth`
is the RFC 9728 route, and the challenge of each refusal is its code's.
JWS and JWK are read in `spindle-http`, which both ends link.

*Rejected:* introspection (RFC 7662) as the first validator. It works
for opaque tokens but costs a call to the authorization server per
request, and every server MCP names issues JWTs. It can be a second
validator behind the same `Bearer.make` (*Open*).

### The OAuth client, in `spindle-client`

`Spindle_client.Oauth` discovers the authorization server from a `401`'s
`resource_metadata` or the well-known path, then RFC 8414 and OpenID
Connect Discovery in the order MCP gives; builds the authorization URL
with PKCE `S256`, `state`, `resource` and the scopes chosen as MCP says,
recording the issuer; and hands it to a function of the application's,
which opens the browser. `Oauth.Loopback` catches the redirect on
`127.0.0.1` and a port the system gives (RFC 8252). The code is
redeemed only after `state` and `iss` check. Tokens are kept through an
interface the application implements, keyed by issuer and resource, so
the library writes no file. Its client id is a Client ID Metadata
Document's URL, which a Spindle application can serve as a route, or a
pre-registered one.

### The MCP client

`Spindle_mcp_client.call` takes a tool's name, its arguments and their
description, and the description of what it returns, for a program that
knows the tool; `call_value` takes and gives `Wiretype.Value.t`, for an
agent passing a model's JSON through. An `input_required` is answered
through `~elicit`, a function the caller gives, and retried with a new
id, at most as many rounds as the caller allows. It sends every header
2026-07-28 requires, mirrors `x-mcp-header` arguments, and on a `401`
uses the OAuth client it was given.

## Rules it adds

- **An MCP rule is a row.** A requirement of MCP 2026-07-28 that Spindle
  meets, as a server or as a client, has a row in `test_mcp_spec`, named
  by its page and section, as does one of JSON-RPC 2.0 as MCP uses it.
  OAuth's -- RFC 6750, 7636, 8414, 8707, 9068, 9207 and 9728 -- have
  theirs in `test_oauth_rfc`, JWS's RFC 7515 and 8037 examples among
  them. Why: as with HTTP, review by example misses the MUST nobody
  thought of.
- **An MCP server keeps nothing between requests.** No table of sessions
  or clients; what spans calls is a sealed state or a handle the
  application mints. Why: 2026-07-28 is stateless, and a server with
  several domains, or behind a balancer, has no other way to be right.
- **A token is checked against its audience.** No bearer token is
  accepted whose `aud` is not the resource's canonical URI, or whose
  `alg` is `none` or an HMAC. Why: a token for another server replayed
  here is the confused deputy MCP's security considerations name.
- *Revised:* **`invalid_arg` is raised in these places alone** gains
  `Spindle_mcp.routes` (two tools of one name, a name MCP refuses, a tool
  reading two argument descriptions or one that is no object) and
  `Spindle.Bearer.make` (an issuer or a resource that is no absolute URI
  without a fragment).
- *Revised:* **its client links no framework** names `spindle-client` and
  `spindle-mcp-client`, neither linking `spindle`, and `spindle` linking
  neither.
- *Revised:* **A secret has no span** names a tool's arguments, a
  `requestState`, a token and its claims; a span's name is the MCP
  method, `tools/call`, never a tool's name, which a caller chooses.

## Stages

- [x] 1. `spindle-http` and `spindle-client` as packages of their own.
- [ ] 2. Bearer tokens: JWS and JWK in `spindle-http`, `Spindle.Bearer`
  and its metadata route, `Spindle_client.Oauth.keys`, the OpenAPI
  security scheme; node-oidc-provider in the suite.
- [ ] 3. The MCP server over HTTP: the protocol library, `server/discover`,
  tools, the validation and errors of FR-5 and FR-6, cacheable lists,
  `Mcp.Test`.
- [ ] 4. Progress and cancellation.
- [ ] 5. Elicitation by MRTR, and sealed state.
- [ ] 6. Resources, resource templates and prompts.
- [ ] 7. `subscriptions/listen`.
- [ ] 8. The MCP client over HTTP.
- [ ] 9. The OAuth client, and the MCP client's use of it.

Each stage brings its guide page and examples, its rows and its line in
`CHANGES.md`.

## Verification

- `make test` runs `test_mcp_spec` and `test_oauth_rfc` whole, the server
  in memory under `Spindle.Test`, expiries on virtual time.
- Properties: a token, a JWS or a sealed state with any byte changed is
  refused; a message the protocol library writes reads back as itself.
- Against node-oidc-provider, run by the suite: a token it
  issues is accepted, one it issues for another resource is refused, and
  the OAuth client completes a sign-in with a scripted browser.
- Interoperability, in CI with Bun: the official TypeScript SDK's client
  runs scenarios 1 to 4 against an example server, and our client
  runs 5 and 6 against the SDK's reference server.
- By hand, once: Claude Code connects to the example server, signs in and
  calls a tool.

## Open

1. **Introspection.** Proposed: RFC 7662, for opaque tokens, as a second
   validator behind `Bearer.make`, once an application asks. Blocks
   nothing.
2. **Which authorization server the tests run.** It must issue RFC 9068
   tokens with the audience RFC 8707's `resource` names, answer with
   `iss` (RFC 9207) and accept Client ID Metadata Documents. Proposed:
   node-oidc-provider, OpenID Certified, which implements each of them,
   configured by a script of the suite's own, so a row gets exactly the
   issuer it needs; its Client ID Metadata Documents are experimental and
   at draft 02 where MCP cites draft 00. Keycloak was weighed and left:
   it has long ignored `resource`, the audience MCP binds a token to.
   Agreed. Undecided: whether it runs on Bun, which CI has, or needs
   Node, which stage 2 finds out.
3. **Resource templates.** RFC 6570 is large; proposed: level 1, `{name}`
   alone, read by a parser of its own. Blocks stage 6.
4. **`x-mcp-header` on a server's tools.** Optional for a server; it
   needs Wiretype to carry an annotation into the schema. Proposed: not
   until a user asks. The client's side is required and is stage 8.
5. **The official conformance suite.** Whether MCP's covers 2026-07-28
   and can run in CI. Blocks nothing; strengthens *Verification*.

## Where the facts go

| Fact | Goes to |
|---|---|
| The packages and what each links | `AGENTS.md`, *Layout* and *Changes and releases*; `dune-project` |
| Each module's contract | `spindle-mcp`'s, `spindle-mcp-client`'s and `Spindle.Bearer`'s `.mli`s |
| How to serve and call MCP, and protect a route with OAuth | new guide pages, `guide/mcp.md` and `guide/oauth.md`, their programs in `examples/` |
| The rules above | `AGENTS.md`, *Rules that must hold* |
| The renames and every addition | `CHANGES.md` |
