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

`open Spindle.Syntax` brings in `let+` and `and+` and nothing else. Every
line runs before the body, which sees plain values: an `int64`, an
`int option`, a time.

- **A bad request is answered all at once.** Every input that is wrong is a
  problem at its place -- `path.user_id`, `query.page`,
  `body.items[2].count` -- collected into one `400`. The handler never runs.
- **A route's inputs are known without running it.** That is what the API's
  [document](openapi.md) is made from.
- **A dependency can be made of other dependencies**, and a route lists it
  just like a built-in.

## Custom dependencies

A page of a list is two query parameters, read as one value and checked:

```ocaml
--8<-- "dependencies.ml:paging"
```

A route lists it like any built-in:

```ocaml
--8<-- "dependencies.ml:route"
```

```sh
curl 'localhost:8080/books?page=2&per_page=2'
```

```text
["Persuasion","Ulysses"]
```

```sh
curl 'localhost:8080/books?page=0'
```

```text
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"query.page","code":"too_small","message":"This is 1 or more."}]}
```

```sh
curl 'localhost:8080/books?page=two&per_page=x'
```

```text
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"query.page","code":"malformed","message":"This is not a whole number."},{"at":"query.per_page","code":"malformed","message":"This is not a whole number."}]}
```

- `Dep.join` turns a check that returns a `result` into a dependency: an
  `Error` refuses the request.
- `Dep.problem ~at ~code message` reports a wrong value at its place,
  alongside every other problem in the request.

??? example "The whole app"

    ```ocaml
    --8<-- "dependencies.ml"
    ```

## Custom error codes

For a refusal that isn't "this input is wrong", declare a code and list it
with `~refuses`, so the route's document names it. A bearer token read from
the `Authorization` header:

```ocaml
let signed_out =
  Spindle.Refusal.Code.make ~challenge:{|Bearer realm="api"|} "signed_out"
    ~status:`Unauthorized ~doc:"Nobody is signed in."

let bearer =
  Spindle.Dep.join ~refuses:[ signed_out ]
    (let+ credentials =
       Spindle.Header.optional "authorization" Spindle.Codec.credentials
     in
     match credentials with
     | Some { scheme = "bearer"; value = Token68 token } -> Ok token
     | Some _ | None -> Error (Spindle.Refusal.make signed_out "Please sign in."))
```

- The header is `optional`: a missing token should be a `401`, not a `400`.
- A `401` code needs a `~challenge` (the `WWW-Authenticate` value);
  the app refuses to start without one.
- Unlike an input problem, a refusal like this ends the request at once.
- The dependency hands over the token, not the account. Looking the account
  up is a read, and belongs in the handler, next to the work it authorises.

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

- **Codecs**: `string`, `int`, `int64`, `float`, `bool`, `uuid`, `date`,
  `instant`, `enum ~kind to_string values`, and `custom` for a type of your
  own.
- **Structured headers** have codecs that parse them: `media_type`,
  `accept`, `weighted`, `credentials`, `cache_control`, `forwarded`, and
  `structured_item`, `structured_list`, `structured_dictionary`.

**A cookie is declared once**, with its name and codec. That one value reads
it and sets it:

```ocaml
let visits = Spindle.Cookie.named "visits" Codec.int

Spindle.Cookie.optional visits                   (* an input: int option *)
Spindle.Cookie.make visits 3                     (* a cookie to set *)
Spindle.Cookie.clear visits                      (* removes it *)
```

A handler sets a cookie by listing `Spindle.set_cookie` among its inputs and
calling it. For a cookie holding arbitrary text, use the
`Spindle.Cookie.encoded` codec. Signed and encrypted cookies and sessions
are on [their own page](../guide/cookies.md).

**Other built-ins**: `Spindle.param`, `Spindle.now` (epoch milliseconds),
`Spindle.request`, `Spindle.request_id`, `Spindle.peer`, `Spindle.client`,
`Spindle.body`, `Spindle.json`, `Spindle.body_stream` and
`Spindle.multipart`.

## Large bodies

`Spindle.json` and `Spindle.body` hold the whole body, up to the server's
`max_body`. For an upload too large to hold, read it as it arrives:

- **`Spindle.body_stream ~max ()`** hands the handler a `Spindle.Body.t`,
  limited to the route's own `max` bytes. Read it a part at a time with
  `Body.read`; a failure (too large, stopped arriving) is a value you can
  answer with `Body.refusal`.
- **`Spindle.multipart ~max ()`** is the same body, split into the parts of
  a `multipart/form-data` upload. `Multipart.next` gives a part's head (its
  `name`, `filename` and content type), `Multipart.read` its bytes. Nothing
  is written to a temporary file; where a part goes is up to you.

A stream can only be read while the handler runs, and a route reads one
body, one way: listing a stream beside `Spindle.json` is refused when the app
is made.

## How dependencies run

- **The body is read last.** Everything else runs first, so a request
  refused for a missing token never has its body read.
- **A dependency runs once per request**, however many others use it: two
  dependencies that read the signed-in user make one database read. The
  sharing is by value -- a dependency built anew by calling a function twice
  is a new one. `Dep.uncached d` runs `d` at every use.
- **What the app holds is not a dependency.** A database pool, a client or
  a configuration exists once, at startup; close over it:
  `let routes pool = [ … ]`. [Database](database.md) shows that shape,
  and [why a transaction is not a dependency](database.md#why-a-transaction-is-not-a-dependency).

??? note "Reading what no built-in reads"

    `Dep.of_request f` runs `f` on the `Spindle.Request.t`. Say what it reads
    with `~needs` (a `Custom` need names something the framework has no word
    for) and how it may refuse with `~refuses`, so the document can list it;
    without `~needs` it is opaque. `Dep.bind` is for a dependency that needs
    another's value to decide what to read next; it is opaque too.

Next: [request bodies, responses and errors](bodies.md).
