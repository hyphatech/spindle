# Dependencies

A handler needs things from the request: a path parameter, a query string,
a header, a cookie, the body -- and things derived from them, like who is
signed in or which page of a list was asked for. A handler handed the whole
request and left to dig is one only it can read: nothing else knows what it
takes, and every handler repeats the digging and its error handling.

## How dependencies work

**A handler lists what it reads, and is given typed values.** Each input is
a value of type `'a Spindle.Dep.t`, and a handler is written as the list of
them, with `let+ … and+ …` -- read it as a parameter list:

```ocaml
open Spindle.Syntax

(let+ id = Spindle.param user_id
 and+ page = Spindle.Query.optional "page" Spindle.Codec.int
 and+ now = Spindle.now in
 answer id ~page ~now)
```

`open Spindle.Syntax` brings in `let+` and `and+` and nothing else. Every
line runs before the body, and the body sees plain values: an `int64`, an
`int option`, a time.

**The list is known without running it.** Because each input is a value
that says what it reads and how it may refuse, a route's inputs can be
listed: that is what the API's document, the client's zod schemas and the
`400` answers are made from.

**A bad request is answered all at once.** Every input that is not what it
should be is a problem at its place -- `path.user_id`, `query.page`,
`body.items[2].count` -- and the problems are collected into one answer, so a
client fixes everything in one round trip. The handler never runs on a
request it cannot use.

**A dependency is made of other dependencies.** The signed-in user, a page
of a list, a checked body: each is a value built from the built-ins, listed
by a route exactly as a built-in is, and run once per request however many
times it is listed.

**What the application holds is not a dependency.** A database pool, a
client, a configuration exist once, at startup; the routes are a function
of them, and the request has nothing to say about them.

## A dependency of your own

A page of a list is two query parameters read as one value and checked:

```ocaml
--8<-- "dependencies.ml:paging"
```

A route lists it as it would a built-in:

```ocaml
--8<-- "dependencies.ml:route"
```

```sh
$ curl 'localhost:8080/books?page=2&per_page=2'
["Persuasion","Ulysses"]
$ curl 'localhost:8080/books?page=0'
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"query.page","code":"too_small","message":"This is 1 or more."}]}
$ curl 'localhost:8080/books?page=two&per_page=x'
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"query.page","code":"malformed","message":"This is not a whole number."},{"at":"query.per_page","code":"malformed","message":"This is not a whole number."}]}
```

`Dep.join` turns a check that may fail into a refusal of the request, and
`Dep.problem` reports a value that is wrong at its place, beside every other
problem the request has.

??? example "The whole program"

    ```ocaml
    --8<-- "dependencies.ml"
    ```

## A refusal of your own

A refusal of another kind is a code the application declares, listed with
`~refuses` so the route's document names it. An authorisation header made
into a dependency is this shape:

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

The header is optional, not required, because a missing token is a `401`
and not a malformed request; `Codec.credentials` reads its scheme without
case, as RFC 9110 §11.1 has it, so `bearer abc` is a bearer token. It hands
over the token, never the account: finding whose it is is a read, and a read
belongs in the handler, beside the work it authorises.

??? example "The whole program: a bearer token, and two routes that need it"

    ```ocaml
    --8<-- "bearer_auth.ml"
    ```

A body read and then checked is the same shape. It keeps "the shape is
wrong" (the description's) apart from "the value is wrong" (the
application's own sentence):

```ocaml
let body t check =
  Spindle.Dep.join ~refuses:[ bad_request ]
    (Spindle.Dep.map
       (fun raw ->
         Result.map_error (Spindle.Refusal.make bad_request) (check raw))
       (Spindle.json t))
```

What no built-in reads is written against the request with
`Dep.of_request`, which says what it reads with `~needs` -- a `Custom` need
names what the framework has no word for -- or is opaque. `Dep.bind` is for a
dependency that needs another's value to know what to read next; what it
reads then cannot be listed without running it.

## The inputs

A query parameter, a header and a cookie are typed inputs, each read by a
codec -- the same codecs a path parameter uses, all in `Spindle.Codec`:

```ocaml
module Codec = Spindle.Codec

Spindle.Query.optional "page" Codec.int          (* int option *)
Spindle.Query.required "q" Codec.string          (* string, or a problem *)
Spindle.Query.list "tag" (Codec.enum ~kind:"colour" to_string [ Red; Green ])
Spindle.Header.optional "x-count" Codec.int
```

A codec is `string`, `int`, `int64`, `bool`, an `enum` of words, or
`custom`, and says what it reads (`Codec.shape`). A header with a structure
of its own is read by that structure's parser in `spindle_http`, so its
value is an input like any other and one that does not parse is `invalid`
at its header: `Codec.media_type`, `Codec.accept`, `Codec.weighted`,
`Codec.credentials`, `Codec.cache_control`, `Codec.forwarded`, and
`Codec.structured_item`, `_list` and `_dictionary` for a field defined on
RFC 9651.

```ocaml
let+ ranges = Spindle.Header.optional "accept" Codec.accept in
Spindle_http.Accept.choose_media (Option.value ranges ~default:[]) [ json; csv ]
```

**A cookie is declared once** -- its name and its codec -- and that one
value reads it and sets it, so the name is never spelled twice and a value
is never printed by hand:

```ocaml
let visits = Spindle.Cookie.named "visits" Codec.int

Spindle.Cookie.optional visits                   (* int option, an input *)
set_cookie (Spindle.Cookie.make visits 3)        (* written by the same codec *)
Spindle.Cookie.clear visits                      (* taken out of the browser *)
```

`Spindle.Cookie.encoded` is the codec for any text: it writes a string as one
a cookie can hold and reads it back as it was. The other built-ins are
`Spindle.param`, `Spindle.now`, `Spindle.request`, `Spindle.request_id`,
`Spindle.peer`, `Spindle.client`, `Spindle.body`, `Spindle.json` and
`Spindle.body_stream`. Signed and encrypted cookies, sessions and the
client's address are [their own page](../guide/cookies.md).

## The rules

These make the system small:

- **A dependency is named by its value, not its type.** OCaml has no
  run-time types for a resolver to read, so it costs one word per parameter
  and buys a compile-time check of the whole list.
- **The body is read last.** Everything that does not need it runs first,
  and a refusal there answers the request with the body never read -- so a
  request with no session costs nothing for its megabyte. Only then is the
  body read, once, and `Spindle.body`, `Spindle.json` and `Dep.of_body` see
  it. It is not on `Request.t`, so nothing else can.
- **A large body is read as it arrives.** `Spindle.body_stream ~max ()` is
  the body as a `Spindle.Body.t`, bounded by the route's own `max` rather
  than the server's `max_body`, and the handler reads it a part at a time
  with `Body.read`, which answers every failure -- too large, no room, a
  body that stopped arriving -- as a value for the route to answer, with
  `Body.refusal` or its own words. It keeps up the server's body rate over
  the whole body, measured only while a read waits, holds the budget one
  part at a time, and is the handler's only while it runs: a read after it
  returns reads nothing and is logged. A route reads one body, one way, and
  one that lists a stream beside another body is refused when the app is
  made. **`Spindle.multipart ~max ()`** is the same body already cut at a
  `multipart/form-data`'s boundaries: `Multipart.next` answers a part's head
  -- its `name`, `filename` and `Content-Type` -- and `Multipart.read` its
  bytes as they arrive, a part left unread passed over by the next `next`,
  every failure a value with its refusal. A part's head is bounded by
  `?max_head` (16 KiB), and where a part goes is the route's: nothing is
  written to a temporary file.
- **Every problem at once.** Within a stage the list runs left to right. An
  input that is not what it should be -- a path parameter that does not
  parse, a query parameter missing, a body of the wrong shape -- is
  `400 invalid` with a problem at its place (`path.order_id`, `query.page`,
  `body.items[2].count`), and the problems of one stage are collected into
  one answer. Any other refusal -- a `401` -- ends the request there.
- **A dependency runs once per request.** A value has an identity, made with
  it, and every use of it in a request is given the one answer it gave, a
  refusal included: the signed-in person two dependencies read is one read of
  the database, an input read twice is listed once and its problem reported
  once, and `Spindle.now` is one instant. What is shared is the value, not
  its shape -- a dependency made again, by a function called twice or inside
  a `bind`'s function, is a new one. `Dep.uncached d` is `d` worked out at
  every use. A route that reads nothing twice, and holds no `bind`, keeps no
  table of answers, so sharing costs it nothing.
- **A dependency says what it reads and how it refuses** -- `Dep.needs`,
  `Dep.codes`: the path parameters, query parameters, headers, cookies and
  body it takes, and the codes it may answer. One written with
  `Dep.of_request` says so with `~needs` and `~refuses`, or is `Dep.opaque`,
  as a `bind` is.
- **What the application already holds is closed over, not injected.** A
  pool, a client, a configuration exist once, at startup, and a route is a
  function of them: `let routes pool = [ … ]`. The [database](database.md)
  page is that shape.
- **A dependency hands over an input, and resolving it is the handler's.**
  A session cookie is a dependency; the account it names is a read, and a
  read belongs inside the handler's transaction, beside the work it
  authorises. [A database](database.md#brackets-why-a-transaction-is-not-a-dependency)
  says why.

Next: [bodies, answers and refusals](bodies.md).
