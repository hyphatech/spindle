# Route settings: one name at every level, and a time limit on handlers

**Status: Accepted** — the whole shape; the first two stages have landed.
Date: 2026-10-27

## The problem

A setting an application makes for every route, and a route makes for
itself, is written five ways today:

| Setting | The application | One route |
|---|---|---|
| compression | `~compress:Compress.t` | `~meta:Meta.(empty \|> add Compress.never ())` |
| CORS | `~cors:Cors.t` | a predicate on the application's policy, `Cors.origins ~routes:(fun info -> ...)` |
| body size | `Limits.max_body` | `body_stream ~max`, `multipart ~max`, required; `json` and `body` take none |
| access log level | none | `~meta:Meta.(empty \|> add Meta.access Logs.Debug)` |
| refusal codes | `~refuses` | `~refuses` |

Only the last has one name at both levels. A reader who knows how the
application compresses cannot guess how a route stops it, and a body's
limit is the server's for one input and the route's for another.

`Meta` is where most of the mix comes from. It holds what a route says of
itself (`summary`, `doc`, `tags`), two settings of the framework's
(`Meta.access`, `Compress.never`), and keys of an application's own that
its middleware reads. The last contradicts `Middleware`'s own contract --
"what one route needs is not middleware: it is a dependency, or a function
the route calls, so that a route's needs stay listed in the route" -- and
the middleware guide's example of it, a `noindex` key, is one
`Spindle.add_header` in the route.

Separately, nothing bounds how long a handler runs. `Server.Limits`
bounds every wait on the client; the handler's own waits -- a row lock, an
`Eio.Mutex`, a stream nobody writes to, a library with no deadline -- are
unbounded. One stuck upstream holds every request that reaches it, each
with a connection slot and whatever it took from a pool, until the pool is
empty and routes that never touch it stop answering too; a shutdown waits
out `drain` and cuts them off. A proxy's timeout answers the client but
does not stop the handler, which goes on holding what it holds, and
Spindle's limits are meant to hold with no proxy in front at all.

The owner asked for both: one name for one setting at every level, with
no exception, and a limit on a handler's time.

## Scope

The `spindle` package alone: `core/`, its documentation site and its
examples.

It covers: removing `Meta`; a route's settings as labels with the
application's names and types; a route's own limits, `Route.Limits`, under
`~limits`; a body's size set by the limits alone; and `handler_timeout`.

It does not cover: `spindle-client`, `spindle-postgres`, `spindle-sqlite`,
`spindle-mcp` and `spindle-cli`, beyond following `Route.info`'s new fields;
cancelling a handler whose client has gone, which is a piece of work of its
own; HTTP/2 or TLS.

## User scenarios

1. **A route stops compression.** A route that answers a secret beside
   what the request sent writes `~compress:Compress.none`. Accepted when
   its answers are never compressed while the application's are, and when
   `rg -n 'Meta' core docs examples` finds nothing.
2. **One route allows other sites.** An application with no CORS policy
   gives its public routes `~cors:public`. Accepted when those routes
   answer preflights and carry `Vary: Origin`, the others do neither, and
   the forgery check trusts the policy's origins on those routes alone.
3. **An upload route takes a large body.** A route with
   `~limits:(Route.Limits.make ~max_body:(64 * 1024 * 1024) ())` reads a
   48 MiB stream through `body_stream ()`, while a route without it
   answers the same body `413`. Accepted when both hold, for `json`,
   `body`, `body_stream` and `multipart` alike.
4. **A whole body the budget cannot hold.** Under the default
   `body_budget` of 64 MiB, a route that reads `json` with a `max_body` of
   128 MiB is answered `500` for any body, with an `error` line naming the
   route and both values, and `Test.call` raises; the same route reading
   `body_stream ()` takes a 100 MiB body. Accepted when both hold, with the
   128 MiB set on the route and again on the application.
5. **A stuck handler.** A route whose handler waits on a promise nobody
   resolves, under an application `handler_timeout` of 10 s, is answered
   `503 timed_out` at 10 s, its handler cancelled, a `warn` line naming the
   route and the limit. Accepted on `In_memory`'s virtual time.
6. **A route that needs longer.** The same route with
   `~limits:(Route.Limits.make ~handler_timeout:Mtime.Span.(2 * min) ())`
   is answered by its handler at 90 s. Accepted on virtual time.
7. **A slow upload is not the handler's time.** A body that keeps up
   `min_body_rate` for longer than `handler_timeout` is read to its end and
   answered. Accepted on virtual time.
8. **A stream outlives the limit.** An events stream and a WebSocket
   answer, then run past `handler_timeout`, and are not ended by it.

## Requirements

- **FR-1** A setting that exists at the application's level and a route's
  has one name and one type at both. A route that sets it replaces the
  application's value for itself, in either direction; one that does not
  has the application's.
- **FR-2** `Meta` is removed. What a route says of itself and the
  framework's settings for it are labels on the route and fields of
  `Route.info`.
- **FR-3** A route can stop compression and can carry a CORS policy of its
  own, with the application's types.
- **FR-4** A route can set its own `max_body`, `body_timeout`,
  `min_body_rate` and `handler_timeout`, and nothing a route cannot apply.
- **FR-5** A body's size has one source for every input: the route's
  limits, else the application's.
- **FR-6** A route that reads its body whole with a `max_body` the body
  budget cannot hold is reported as the route's bug, the same whether the
  `max_body` is its own or the application's.
- **FR-7** A handler that runs past its `handler_timeout` is cancelled,
  with everything it started under it, and answered `503`, with a code of
  its own that every route's document lists.
- **FR-8** Time spent waiting on the client's body is not the handler's
  time, and a stream or a socket after its answer is not bounded by it.

## Design

### The rule

**A setting has one name at every level.** Where it is set follows what it
governs -- the application, a route, an input, an answer -- and an
override has exactly the name and the type of the default it overrides.
What exists at one level only has nothing to mirror: `access_log` and a
stream's `keep_alive` are a route's and an answer's alone; `port`,
`domains`, `middleware`, `check_origin` and the rest are the application's
alone.

### A route

```ocaml
type ('r, 'a, 'k) maker =
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?access_log:Logs.level ->
  ?compress:Compress.t ->
  ?cors:Cors.t ->
  ?limits:Route.Limits.t ->
  ('a, 'k) Path.t ->
  'r Returns.t ->
  'r Dep.t ->
  t
```

| Label | The application's | Absent |
|---|---|---|
| `?refuses` | `~refuses` | the route's inputs' codes alone, as today |
| `?compress` | `~compress` | the application's policy |
| `?cors` | `~cors` | the application's policy |
| `?limits` | `~limits` (`Server.Limits.t`) | the application's, field by field |
| `?access_log` | none | `Info` |

`?access_log` is the level of the route's line in the access log, as
`Meta.access` was. It is not `?access`, since `Spindle.Access` decides who
may do what, and `~access:Logs.Debug` beside it would read as a
permission.

`Compress.none` and `Cors.none` are policies that compress nothing and
allow no other site, so a route turns either off with the type it would
turn it on with. `Cors.origins` and `Cors.any` lose `?routes`: the route
carries its policy. A preflight is answered by the policy of the route
whose method it asks for, and the forgery check, which already runs once
the route is matched, trusts the matched route's origins; an unmatched
request has the application's.

Routes that share settings share a maker, by partial application:

```ocaml
let api_get = Spindle.get ~cors:public ~limits:api_limits
let api_post = Spindle.post ~cors:public ~limits:api_limits
```

`Route.info` loses `meta : Meta.t` and gains `summary : string option`,
`doc : string option`, `tags : string list`, `access_log : Logs.level`,
and `compress : Compress.t option` and `cors : Cors.t option`, the route's
own policies where it gave them.
`Route.pp`, the OpenAPI document and `spindle-mcp` read them there.

### Limits

`~limits` is the name at both levels. The two types differ, because most
of the application's limits cannot apply to one route: they act before a
route is chosen, between requests, or on the whole server. The fields
they share have one name and one meaning.

```ocaml
module Server.Limits : sig
  val make :
    ?max_body:int ->
    ?body_timeout:Mtime.Span.t ->
    ?min_body_rate:int ->
    ?handler_timeout:Mtime.Span.t ->
    ?send_timeout:Mtime.Span.t ->
    ?discard_limit:int ->
    ?body_budget:int ->
    ?max_header_bytes:int ->
    ?head_timeout:Mtime.Span.t ->
    ?idle_timeout:Mtime.Span.t ->
    ?max_connections:int ->
    ?backlog:int ->
    ?linger:Mtime.Span.t ->
    ?drain:Mtime.Span.t ->
    unit ->
    t
end

module Route.Limits : sig
  val make :
    ?max_body:int ->
    ?body_timeout:Mtime.Span.t ->
    ?min_body_rate:int ->
    ?handler_timeout:Mtime.Span.t ->
    unit ->
    t
end
```

| Limit | A route may set it | Why |
|---|---|---|
| `max_body`, `body_timeout`, `min_body_rate` | yes | a body is read only when its route asks, once the route is chosen (`core/server.ml`, `whole` and `part`) |
| `handler_timeout` | yes | it starts with the handler |
| `send_timeout`, `discard_limit`, `body_budget` | no | the connection's, or every request's at once |
| `max_header_bytes`, `head_timeout` | no | before a route is chosen |
| `idle_timeout`, `linger` | no | between requests, or after the last |
| `max_connections`, `backlog`, `drain` | no | the server's |

`Route.Limits.make` refuses a value out of range as `Server.Limits.make`
does, with `Invalid_argument`, where it is written. `body_stream` and
`multipart` lose `~max`; every input's size is the route's `max_body`,
else the application's.

`body_budget` is the memory every body held at once shares, so it is the
application's alone. A body read whole -- `Dep.body`'s `Raw`, `Json` or
`Form` -- is held, so it must fit the budget; a `Stream` holds one part at
a time, so it need not, which is how an upload larger than memory is
taken. A route that reads its body whole with a `max_body`, its own or the
application's, above `body_budget` can never hold a body between the two,
and would answer each `503 busy`, which reads as an overloaded server. It
is the route's bug, found where the body is read whole, whatever the size
of the body sent: `500`, an `error` line naming the route, its `max_body`
and the budget, and `Test.call` raises. The check is at the read and not
where the application is made, because a route whose body is read behind a
`Dep.bind` does not say whether it reads it whole; one place serves every
route, and the first test that sends one a body finds it.

```ocaml
(* the application: max_body 1 MiB, body_budget 64 MiB *)

(* read whole, 10 MiB: within the budget *)
Spindle.post ~limits:(Spindle.Route.Limits.make ~max_body:(10 * 1024 * 1024) ()) ...
  (let+ rows = Spindle.json rows_json in ...)

(* streamed, 1 GiB: one part held at a time *)
Spindle.post ~limits:(Spindle.Route.Limits.make ~max_body:(1024 * 1024 * 1024) ()) ...
  (let+ body = Spindle.body_stream () in ...)

(* read whole, 128 MiB: above the budget, the route's bug *)
Spindle.post ~limits:(Spindle.Route.Limits.make ~max_body:(128 * 1024 * 1024) ()) ...
  (let+ rows = Spindle.json rows_json in ...)
```

### The handler's time

`handler_timeout` bounds the application's own work: from the route being
chosen until its answer is in hand. It is 60 s unless set: on by default,
since an application that never sets it is the one a stuck upstream takes
down, and longer than `spindle-client`'s 30 s call deadline, so a call's
own timeout reaches the handler first and it answers its own error. Time a body read spends waiting on the
client is not counted, since `body_timeout` and `min_body_rate` already
bound it and a slow upload they allow must not be cut by a second limit.
Writing the answer is not counted either: `send_timeout` bounds it, and an
events stream or a socket runs after its answer, under `keep_alive` and
`send_timeout`.

Past it, the handler's fiber is cancelled, and with it every dependency
and every fiber it forked on its switch. A database statement in flight
closes its connection, so its transaction ends with nothing kept, as
`rowtype` already does on cancellation. Work handed to `Background` runs
on its domain's switch and is not cancelled. The answer is a new refusal:

```ocaml
val timed_out : t
(** The handler ran past its [handler_timeout]: [503 timed_out]. *)
```

```console
HTTP/1.1 503 Service Unavailable
content-type: application/json

{"error":"timed_out","message":"This took longer than the server allows."}
```

It carries no `Retry-After`, since nothing says a second try will be
faster. `timed_out` is among the framework's codes every route's document
lists, as `busy` is, and a `warn` line names the route and its limit.

### Alternatives rejected

- **Keep `Meta` for keys of an application's own.** No program defines
  one, and the one use documented, a per-route policy read by middleware,
  is what `Middleware`'s contract says a route does with a dependency.
- **The framework's settings as `Meta` keys, as `Compress.never` is.** A
  setting in an open map is in no signature, and the map mixes it with a
  route's description.
- **Every limit a flat label, on `serve` and on the route.** `serve` took
  the thirteen limits as labels until they were grouped into
  `Server.Limits`, because the list was too long; flattening them again
  undoes that.
- **One limits type at both levels.** A route could then be given a
  `backlog`, which compiles and does nothing.
- **Two names for the two groups, a server's and a route's.** One idea
  under two names reads as two ideas; the label is the same and the type
  says which limits it holds.
- **A body's size on its input, `json ?max_body`.** It would leave two
  places a route's body size is set, its limits and its input.
- **Leaving the handler's time to a proxy.** A proxy's timeout answers its
  client and leaves the handler holding its slot and its pool connection.
- **`504`.** RFC 9110 gives it to a gateway whose upstream did not answer;
  a Spindle application is the origin server.
- **`busy`.** It says something the request needed did not come free; a
  client should tell a full server from a slow request.
- **Counting the body's wait as the handler's time.** An upload within
  `body_timeout` and `min_body_rate` would be cut by `handler_timeout`, two
  limits disagreeing on one request.

## Rules it adds

- **A setting has one name at every level.** A setting a route, an input
  or an answer overrides has the name and the type of the application's,
  and one that exists at one level only has no twin under another name;
  a reader who knows one level knows the other. Symptom: a route label or
  an input argument whose name is not the application's for the same
  setting, or a type that differs under one name.
- Revises **A socket's failures are values, and so are a stream's**:
  nothing in the framework cancels a handler whose peer has gone; a
  handler past its `handler_timeout` is cancelled, and a transaction under
  it ends with nothing kept.
- Revises **A limit is a dependency** to **A rate limit is a dependency**:
  the rule is `Rate.limit`'s, and `Route.Limits` are not dependencies.
- Adds to **`invalid_arg` is raised in these places alone**:
  `Spindle.Route.Limits.make`, for a limit out of its range; and
  `Spindle.Test.call` also refuses a route that reads its body whole with a
  `max_body` above `body_budget`.

## Stages

- [x] **`Meta` removed.** `?access_log` and `?compress` on the route,
      `Compress.none`, `Route.info`'s fields; the middleware guide's
      example becomes `Spindle.add_header` in the route. Breaking.
- [x] **A route's CORS.** `?cors` on the route, `Cors.none`, `?routes`
      gone; the preflight and the forgery check read the matched route's
      policy. Breaking.
- [ ] **A route's limits.** `Route.Limits` with `max_body`,
      `body_timeout` and `min_body_rate`; `?limits` on the route;
      `body_stream` and `multipart` lose `~max`; a whole read above the
      budget is the route's bug. Breaking.
- [ ] **`handler_timeout`.** In `Server.Limits` and `Route.Limits`;
      `Refusal.timed_out`; the body's wait and the answer's write left
      out; the `warn` line; the document's code.

## Verification

`make test` and `make lint` pass, and `test_spindle` holds a case for each
user scenario, every time-bound one on `In_memory`'s virtual time. The
documentation site's examples compile and run under `test_docs`, and `rg
-n 'Meta\b' core docs examples` and `rg -n '~max:' docs examples` find
nothing.

## Open

- **`send_timeout` in `Route.Limits`.** A large download to a slow client
  may need longer than the rest; it is the connection's today. Blocks
  nothing; it can join later by the same rule.

## Where the facts go

| Fact | Its owner |
|---|---|
| `Route.Limits`, `Compress.none`, `Cors.none`, `Refusal.timed_out`, the maker's labels, `Route.info`'s fields | their `.mli` |
| How a route sets its own compression, CORS and limits, and the handler's time | the documentation site: `guide/serving.md`, `guide/compression.md`, `guide/middleware.mdx`, `tutorial/routes.mdx`, `tutorial/bodies.mdx` |
| *A setting has one name at every level*, the revised rules and the `invalid_arg` places | *Rules that must hold* in `AGENTS.md` |
| Each breaking change | `CHANGES.md`, under `## Unreleased` |
| Why, and what was weighed | the commit messages |
