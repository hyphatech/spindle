---
title: Request bodies, responses and errors
---

This page reads a JSON body, answers with JSON, and says no. Each is a value
declared on the route, so the API's document always matches what the route
does.

## JSON in, JSON out

An order is a record whose quantity has bounds. What was placed is another
record, answered at `201`. An item that is sold out is a refusal the
application declares:

```ocaml
--8<-- "json_body.ml:app"
```

```console
$ curl -i localhost:8080/orders -H 'content-type: application/json' \
    -d '{"item": "tea", "quantity": 2}'
HTTP/1.1 201 Created
content-type: application/json
...

{"number":1,"item":"tea","quantity":2}
```

A body of the wrong shape is answered before your handler runs, with every
problem at once:

```console
$ curl localhost:8080/orders -H 'content-type: application/json' \
    -d '{"quantity": "two"}'
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"body.quantity","code":"unexpected_type","message":"This must be a whole number, not text."},{"at":"body.item","code":"required","message":"This is required."}]}

$ curl localhost:8080/orders -H 'content-type: application/json' \
    -d '{"item": "tea", "quantity": 0}'
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"body.quantity","code":"too_small","message":"This must be at least 1."}]}
```

A rule only your data can check is the handler's own refusal:

```console
$ curl -i localhost:8080/orders -H 'content-type: application/json' \
    -d '{"item": "cake", "quantity": 1}'
HTTP/1.1 409 Conflict
content-type: application/json
...

{"error":"sold_out","message":"There is no cake left today."}
```

What happened:

- `[@@deriving wiretype]` gives each record a description, `order_json` and
  `placed_json`. The same value decodes the body, encodes the answer and
  describes the shape in the API's document. A shape the deriver cannot
  describe is written with
  [`wiretype`'s combinators](https://github.com/hyphatech/wiretype#by-hand).
- `Spindle.json order_json` reads the body. Types, required fields and bounds
  like `[@min 1]` are checked for you; a body that fails is a `400`.
- ``Returns.json ~status:`Created placed_json`` declares the answer. The
  handler returns the plain record and the framework encodes it.
- `sold_out` is a refusal code, declared once with its status. The route
  lists it in `~refuses`.

<details>
<summary>The whole app</summary>

```ocaml
--8<-- "json_body.ml"
```

</details>

## Response types

A route is `Spindle.get`, `post`, `put`, `patch` or `delete` (or
`Spindle.route meth`), then a path, what it returns, and its inputs. What it
returns decides what the handler must give back:

```ocaml
Spindle.get path Returns.html
  (let+ ... in Ok page)                                  (* a page, 200 *)

Spindle.get path Returns.text
  (let+ ... in Ok "Hello.")                              (* text, 200 *)

Spindle.post path (Returns.json ~status:`Accepted verdict_json)
  (let+ ... in Ok verdict)                               (* a value, encoded *)

Spindle.post path (Returns.empty ())
  (let+ ... in Ok ())                                    (* nothing, 204 *)

Spindle.get path Returns.response
  (let+ ... in Ok (Response.redirect "/there"))          (* a response of its own *)

Spindle.get path (Returns.events Event.[ declare state ])
  (let+ ... in Ok (fun send -> ...))                     (* declared events *)

Spindle.get path (Returns.websocket chat)
  (let+ ... in Ok (fun ws -> ...))                       (* a WebSocket *)
```

`Returns.json` defaults to `200` and `Returns.empty` to `204`. Event streams
have [their own guide](/spindle/guide/sse/), and so do
[WebSockets](/spindle/guide/websockets/).

**When success can be one of several statuses** -- made or replaced, queued
or done -- list them, each with a sentence for the document, and return the
one you reached beside the value:

```ocaml
Spindle.put Path.(s "users" / user_id)
  (Returns.json_response user_json
     ~statuses:[ (`Created, "The user was made."); (`OK, "The user was replaced.") ])
  (let+ pool = db
   and+ id = Spindle.param user_id
   and+ body = Spindle.json user_json in
   match upsert pool id body with
   | Ok (`Made u) -> Ok (`Created, u)
   | Ok (`Replaced u) -> Ok (`OK, u)
   | Error e -> Error (Spindle_sqlite.refusal e))
```

`Returns.empty_response ~statuses` is the same with no body: the handler
returns `` Ok `Created `` or `` Ok `No_content ``. Every listed status must
be a `2xx`; failing is a refusal. A JSON answer is never `204` or `205`,
which HTTP sends without a body: an answer with nothing to say is
`Returns.empty`'s.

## Setting cookies and headers

To set a cookie or a header, take `Spindle.set_cookie` or
`Spindle.add_header` as an input -- each is a function -- and call it:

```ocaml
let visits = Spindle.Cookie.named "visits" Spindle.Codec.int

Spindle.get Path.(s "welcome") Returns.text
  (let+ set_cookie = Spindle.set_cookie
   and+ add_header = Spindle.add_header in
   set_cookie (Spindle.Cookie.make visits 3);
   add_header ("cache-control", "max-age=60");
   Ok "Welcome back.")
```

- What you set is sent with the answer, an `Ok` or a refusal: a session moved
  before a refusal still tells the browser where it went. A field the refusal
  writes itself, such as `Retry-After`, is sent in place of yours.
- Set cookies with `set_cookie`, never with `add_header ("set-cookie", …)`.
- Some fields are the server's alone to write. A handler that sets one of
  them itself, or a header value containing a line break, answers `500`:
    - how the answer is framed: `Content-Length`, `Transfer-Encoding`,
      `Connection`, `Keep-Alive`, `Upgrade`, `TE` and `Trailer`;
    - what the server derives: `Content-Type` (from the route's `Returns`),
      `Set-Cookie` (from `set_cookie`), `Date` and `X-Request-Id`.
- To end the connection after an answer, return
  `Response.close_connection response` from a `Returns.response` route.

Signing in and out with a session is shown in
[Sessions](/spindle/guide/cookies/#sessions).

A route that builds its own answer uses `Returns.response` and `Response`:
`make`, `html`, `json`, `empty`, `redirect`, `stream`, `events`, `refusal`,
and `takeover` for a protocol spoken after HTTP (see the
[`Response` reference](/spindle/reference/spindle/Spindle/Response/index.html)).

## Errors

An `Error` is always a `Refusal.t`, made from a **code** you declare once
with its status and meaning:

```ocaml
let conflict =
  Refusal.Code.make "conflict" ~status:`Conflict ~doc:"Somebody moved first."

Error (Refusal.make ~detail:(Store.error_to_string e) conflict
         "Somebody moved first.")
```

The client gets `{"error": "conflict", "message": "Somebody moved first."}`.
The `~detail` goes to the log only.

- **List your codes** in the route's `~refuses`. Codes its inputs bring (a
  JSON body's `unsupported_media_type`, say) are added for you, and so are
  the framework's own the route's document lists from what it reads:
  `invalid` where it reads an input, `unreadable` and `too_large` where it
  reads a body, `cross_origin` for a method that changes something,
  `upgrade_required` for a WebSocket, and `busy` and `internal` everywhere.
  Any other -- `Refusal.not_found` from a handler, say -- goes in `~refuses`
  like your own. A code nobody declared is still answered, but logged as a
  bug, and `Spindle.Test.call` raises on it.
- **A name means one thing.** Two codes with the same name but a different
  status or doc are refused when the app is made.
- **A code fails, and an answer succeeds.** A code's status is `4xx` or
  `5xx`, and `Returns.json ~status` or `Returns.empty ~status` is `2xx`;
  either the other way round is refused when the app is made.
- **A `401` code needs `~challenge`**, the `WWW-Authenticate` value, e.g.
  `~challenge:{|Bearer realm="api"|}`.
- **Your own answer for a bad body**:
  `Spindle.json ~refusal:(bad_body, "That is not an order.") order_json`,
  where `bad_body` is a code you made with `Refusal.Code.make`. The
  dependency declares it for you. The client gets only your code and
  sentence; the list of problems goes to the log.

## Forms and file uploads

A form's fields are typed inputs, read like query parameters. A wrong one is
a problem at `form.<name>`:

```ocaml
let email = Spindle.Form.required "email" Spindle.Codec.string
let remember = Spindle.Form.checked "remember"

Spindle.post Path.(s "sign-up") (Spindle.Returns.json account_json)
  (let+ email = email and+ remember = remember in
   sign_up ~email ~remember)
```

- `Form.required`, `optional` and `list` take a codec. `checked` is `true`
  when the field was sent at all, since an unticked box is not sent.
- The body is read once, however many fields you read, as
  `application/x-www-form-urlencoded` or `multipart/form-data`, up to the
  server's `max_body`. Any other `Content-Type` is `415`.
- A route reads one body: a form field beside `Spindle.json` is refused when
  the app is made.
- **Files** are `Form.File.required`, `optional` and `list`, each a
  `Form.File.t` with a `filename` (text a person chose, never a path to
  trust), a `content_type` and the `content`. An upload too large to hold
  in memory is read with `Spindle.multipart` ([large bodies](#large-bodies)).

**No CSRF token is needed.** A cross-site `POST` is refused with `403
cross_origin` before any route sees it. `~check_origin:false` on
`Spindle.serve` turns that check off, and with it your forms' protection;
to accept another site of your own, list it in `~trusted_origins` instead.

## Large bodies

`Spindle.json` and `Spindle.body` hold the whole body, up to the server's
`max_body`. For an upload too large to hold, read it as it arrives:

- **`Spindle.body_stream ~max ()`** hands the handler a `Spindle.Body.t`,
  limited to the route's own `max` bytes. Read it a part at a time with
  `Body.read`. A failure (too large, stopped arriving) is already the
  refusal to answer with, so `let* part = Spindle.Body.read body in` goes on
  through it, as a session's does.
- **`~content_types:[ "text/csv" ]`** accepts only those types, each
  `type/subtype`, `type/*` or `type/*+suffix`, compared without case or
  parameters. Any other type is answered `415` before a byte is read, and
  the API's document lists them as the body's types.
- **`Spindle.multipart ~max ()`** is the same body, split into the parts of
  a `multipart/form-data` upload. `Multipart.next` gives a part's head (its
  `name`, `filename` and content type), `Multipart.read` its bytes. Their
  failures are refusals too. Nothing
  is written to a temporary file; where a part goes is up to you.

A stream can only be read while the handler runs. A route reads one body,
one way: listing a stream beside `Spindle.json` is refused when the app is
made.
