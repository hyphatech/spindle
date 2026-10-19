# Dependencies

A handler needs things from the request: a path parameter, a query string,
a header, a cookie, the body -- and things built from them, like who is
signed in or which page of a list was asked for. Each of these is a
*dependency*, and a handler lists the ones it reads.

## How it works

Each input is a value of type `'a Spindle.Dep.t`. A handler lists them with
`let+ … and+ …` -- read it as a parameter list:

```ocaml
open Spindle.Syntax

(let+ id = Spindle.param user_id
 and+ page = Spindle.Query.optional "page" Spindle.Codec.int
 and+ now = Spindle.now in
 answer id ~page ~now)
```

`open Spindle.Syntax` brings in `let+` and `and+`, and `let*` for the
`result` a handler answers (`Result.bind`), and nothing else. Every
input is worked out before the code after `in` runs, and that code sees
plain values: an `int64` (if `user_id` is a `Path.int64`), an `int option`,
a `Ptime.t`.

- **A bad request is answered all at once.** Every wrong path parameter,
  query parameter, header and cookie is reported in one `400`, each problem
  at its place (`path.user_id`, `query.page`). Only when those are all fine
  is the body read, and its problems (`body.items[2].count`) are then
  reported together the same way. The handler never runs.
- **A route's inputs are known without running it.** That is what the API's
  [document](openapi.md) is made from.
- **A dependency can be made of other dependencies**, and a route lists it
  just like a built-in.

## A query parameter

A query parameter is read with the codec of its type, so the handler is
handed a `float` and is arithmetic and nothing else:

```ocaml
--8<-- "fahrenheit.ml:app"
```

```console
$ curl 'localhost:8080/fahrenheit?celsius=21'
{"fahrenheit":69.8}

$ curl 'localhost:8080/fahrenheit?celsius=warm'
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"query.celsius","code":"malformed","message":"This is not a number."}]}

$ curl localhost:8080/fahrenheit
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"query.celsius","code":"required","message":"This is required."}]}
```

- `Query.required` refuses a missing parameter; `Query.optional` hands over
  an `option`, and `Query.list` every value given.
- `Openapi.docs routes` serves the API's own document beside it: the
  [OpenAPI](openapi.md) page.

## Custom dependencies

A page of a list is two query parameters, read as one value and checked:

```ocaml
--8<-- "dependencies.ml:paging"
```

A route lists it like any built-in:

```ocaml
--8<-- "dependencies.ml:route"
```

```console
$ curl 'localhost:8080/books?page=2&per_page=2'
["Persuasion","Ulysses"]

$ curl 'localhost:8080/books?page=0'
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"query.page","code":"too_small","message":"This is 1 or more."}]}

$ curl 'localhost:8080/books?page=two&per_page=x'
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"query.page","code":"malformed","message":"This is not a whole number."},{"at":"query.per_page","code":"malformed","message":"This is not a whole number."}]}
```

- `Dep.join` makes a dependency that may refuse, as `paging` above does:
  write a `let+` block that answers `Ok` or `Error`, and wrap it. `Ok v`
  gives `v`; `Error` refuses the request. `~refuses` names the codes it may
  refuse with, so the document lists them; a `400` about an input, like
  `paging`'s, needs none.

  ```ocaml
  let bearer =
    Spindle.Dep.join ~refuses:[ signed_out ]
      (let+ token = Spindle.Header.optional "authorization" Spindle.Codec.string in
       Option.to_result ~none:(Spindle.Refusal.make signed_out "Sign in.") token)
  ```
- `Dep.problem ~at ~code message` reports a wrong value at its place,
  alongside every other problem in the request.
- `Dep.map f d` derives a value that cannot fail:
  `Spindle.Dep.map String.lowercase_ascii email`.
- `Dep.refuse refusal` always refuses, for a route that is switched off.
- `Dep.of_body ~need:(Raw { content_types = [ "text/csv" ] }) parse` reads
  the whole body as a string and parses it into a type of your own. A
  request of any other `Content-Type` is answered `415` before its body is
  read.

??? example "The whole app"

    ```ocaml
    --8<-- "dependencies.ml"
    ```

## Custom error codes

For a refusal that isn't "this input is wrong", declare a code and list it
with `~refuses`, so the route's document names it. A bearer token read from
the `Authorization` header:

```ocaml
--8<-- "bearer_auth.ml:bearer"
```

- The header is `optional`: a missing token should be a `401`, not a `400`.
- A `401` code needs a `~challenge` (the `WWW-Authenticate` value);
  the app refuses to start without one.
- Unlike an input problem, a refusal like this ends the request at once.
- `Dep.credential ~scheme:"bearer"` tells the [document](openapi.md) that
  this input proves who is asking, so it lists the scheme and which routes
  need it.
- The dependency hands over the token, not the account. Looking the account
  up is a read, and belongs in the handler, next to the work it authorises
  ([why](database.md#why-a-transaction-is-not-a-dependency)).

??? example "The whole app: a bearer token, and two routes that need it"

    ```ocaml
    --8<-- "bearer_auth.ml"
    ```

## Query, header and cookie inputs

Query parameters, headers and cookies are read by a codec from
`Spindle.Codec` -- the same codecs a path parameter uses:

```ocaml
module Codec = Spindle.Codec

Spindle.Query.optional "page" Codec.int          (* int option *)
Spindle.Query.default "limit" Codec.int 20       (* int: 20 when absent *)
Spindle.Query.required "q" Codec.string          (* string, or a 400 *)
Spindle.Query.list "tag" Codec.string            (* ?tag=a&tag=b *)
Spindle.Header.optional "x-count" Codec.int      (* name matched without case *)
```

- **Codecs**: `string`, `int`, `int64`, `float`, `bool`, `uuid` (a
  `Uuidm.t`, as a JSON body's and a row's), `date`, `instant` (a
  `Ptime.t`), `enum ~kind to_string values`, and `custom` for a type of
  your own.
- **Structured headers** have codecs that parse them: `media_type`,
  `accept`, `weighted`, `credentials`, `cache_control`, `forwarded`, and
  `structured_item`, `structured_list`, `structured_dictionary`.
- **A header sent on several lines** is read whole by a codec of a list --
  `accept`, `weighted`, `cache_control`, `forwarded`, `structured_list`,
  `structured_dictionary`, and a `custom ~list:true` of your own -- its
  lines joined by `, `. To any other codec
  it is malformed, a `400`: a value sent twice is no message HTTP allows.

**A cookie is declared once**, with its name and codec. That one value reads
it and sets it:

```ocaml
let visits = Spindle.Cookie.named "visits" Codec.int

Spindle.Cookie.optional visits                   (* an input: int option *)
Spindle.Cookie.make visits 3                     (* a cookie to set *)
Spindle.Cookie.clear visits                      (* removes it *)
```

A handler sets a cookie by listing `Spindle.set_cookie` among its inputs and
calling it ([how](bodies.md#setting-cookies-and-headers)). For a cookie
holding arbitrary text, use the `Spindle.Cookie.encoded` codec. Signed and
encrypted cookies and sessions are on [their own page](../guide/cookies.md).

**Other built-ins**:

- `Spindle.param`: a path parameter.
- `Spindle.now`: the instant the request is answered at, a `Ptime.t`.
- `Spindle.request`: the whole `Spindle.Request.t`.
- `Spindle.request_id`: the id on every log line of this request.
- `Spindle.peer`: the address that opened the connection, which is the
  proxy when there is one.
- `Spindle.client`: who is asking. It is the peer, or, when the peer is a
  proxy you told the server to trust, the address that proxy forwarded for
  ([the client's IP address](../guide/cookies.md#the-clients-ip-address)).
- `Spindle.set_cookie` and `Spindle.add_header`: functions that add a
  cookie or a header to the answer.
- `Spindle.client_gone`: a promise resolved once the client has gone, for a
  long-running [event stream](../guide/sse.md).
- `Spindle.body`, `Spindle.json`, `Spindle.body_stream` and
  `Spindle.multipart`: the body, [read whole or as it
  arrives](bodies.md#large-bodies).

## How dependencies run

- **The body is read last.** Everything else runs first, so a request
  refused for a missing token never has its body read.
- **A dependency runs once per request**, however many others use it: two
  dependencies that both use `bearer` read the header once.
- **Sharing works by identity.** Define a dependency once, `let current =
  …`, and use that value everywhere. A function `let current () = …` called
  twice makes two dependencies, which run twice. `Dep.uncached d` runs `d`
  at every use on purpose.
- **What the app holds is a resource**: read like any other dependency,
  but supplied once, where the server starts ([below](#resources)).

??? note "Reading what no built-in reads"

    `Dep.of_request f` runs `f` on the `Spindle.Request.t`. Say what it reads
    with `~needs` (a `Custom` need names something the framework has no word
    for) and how it may refuse with `~refuses`, so the document can list it;
    without `~needs` it is opaque. `Dep.bind` is for a dependency that needs
    another's value to decide what to read next; it is opaque too.

## Resources

Every dependency above is request-wide: worked out from the request, once
per request. A resource is app-wide: a database pool, a client, a
[broadcast](../guide/sse.md#broadcasting-to-many-clients) hub, made once
where the program starts. Name it with `Dep.of_resource`, read it like any
other dependency, and supply it when the server starts:

```ocaml
let db : Spindle_postgres.Pool.t Spindle.Dep.t = Spindle.Dep.of_resource "database"

(let+ pool = db and+ id = Spindle.param order_id in ...)

Spindle.serve env ~resources:[ Spindle.Dep.resource db pool ] routes
```

- **The routes stay a value.** They read the pool without holding it, so
  the [command line](client-schemas.md) describes them with no database,
  and a [test](../guide/testing.md) supplies its own.
- **A missing resource stops the server.** A route that reads one
  `~resources` does not hold is refused before the server listens, naming
  the route and the resource; so is one supplied twice. One read inside
  `Dep.bind` is found only as it runs: unsupplied, it is a `500`, logged
  by name.
- **It is no input.** A request does not carry it, so the API's document
  and the client schemas never list it.
- **Make it once, at the top level.** It has an identity, as every
  dependency has: the value supplied is the value read.

[Database](database.md) shows the whole shape, and [why a transaction is
not a dependency](database.md#why-a-transaction-is-not-a-dependency).

Next: [request bodies, responses and errors](bodies.md).
