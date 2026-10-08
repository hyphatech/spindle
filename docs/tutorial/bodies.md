# Request bodies, responses and errors

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

```sh
curl -i localhost:8080/orders -H 'content-type: application/json' \
    -d '{"item": "tea", "quantity": 2}'
```

```text
HTTP/1.1 201 Created
content-type: application/json

{"number":1,"item":"tea","quantity":2}
```

A body of the wrong shape is answered before your endpoint runs, with every
problem at once:

```sh
curl localhost:8080/orders -H 'content-type: application/json' \
    -d '{"quantity": "two"}'
```

```text
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"body.quantity","code":"unexpected_type","message":"This must be a whole number, not text."},{"at":"body.item","code":"required","message":"This is required."}]}
```

```sh
curl localhost:8080/orders -H 'content-type: application/json' \
    -d '{"item": "tea", "quantity": 0}'
```

```text
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"body.quantity","code":"too_small","message":"This must be at least 1."}]}
```

A rule only your data can check is the endpoint's own refusal:

```sh
curl -i localhost:8080/orders -H 'content-type: application/json' \
    -d '{"item": "cake", "quantity": 1}'
```

```text
HTTP/1.1 409 Conflict
content-type: application/json

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
- `Returns.json ~status:`Created placed_json` declares the answer. The
  endpoint returns the plain record and the framework encodes it.
- `sold_out` is a refusal code, declared once with its status. The route
  lists it in `~refuses`.

??? example "The whole app"

    ```ocaml
    --8<-- "json_body.ml"
    ```

## Response types

A route is `Spindle.get`, `post`, `put`, `patch` or `delete` (or
`Spindle.route meth`), then a path, what it returns, and its inputs. What it
returns decides what the endpoint must give back:

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

`Returns.json` defaults to `200` and `Returns.empty` to `204`.

**When success can be one of several statuses** -- made or replaced, queued
or done -- list them, each with a sentence for the document, and return the
one you reached beside the value:

```ocaml
Spindle.put Path.(s "users" / user_id)
  (Returns.json_response user_json
     ~statuses:[ (`Created, "The user was made."); (`OK, "The user was replaced.") ])
  (let+ id = Spindle.param user_id and+ body = Spindle.json user_json in
   match upsert pool id body with
   | Ok (`Made u) -> Ok (`Created, u)
   | Ok (`Replaced u) -> Ok (`OK, u)
   | Error e -> Error (Spindle_postgres.refusal e))
```

`Returns.empty_response ~statuses` is the same with no body: the endpoint
returns `` Ok `Created `` or `` Ok `No_content ``. Every listed status must
be a `2xx`; failing is a refusal.

## Setting cookies and headers

To set a cookie or a header, take `Spindle.set_cookie` or
`Spindle.add_header` as an input -- it is a function -- and call it:

```ocaml
let sign_out session set_cookie =
  Sessions.close session;
  set_cookie clear_session;
  Ok true

Spindle.post Path.(s "sign-out") (Returns.json Wiretype.bool)
  (let+ session = session and+ set_cookie = Spindle.set_cookie in
   sign_out session set_cookie)
```

- What you set is sent with an `Ok` answer only, never with a refusal.
- The framework writes `Content-Type`, `Content-Length` and the other fields
  that frame the answer. Setting one yourself, or a header value containing
  a line break, answers `500`.
- To end the connection after an answer, return
  `Response.close_connection response` from a `Returns.response` route.

A route that builds its own answer uses `Returns.response` and `Response`:
`make`, `html`, `json`, `empty`, `redirect`, `stream`, `events`, `refusal`,
and `takeover` for a protocol spoken after HTTP (see the `Response`
reference).

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
  JSON body's `unsupported_media_type`, say) are added for you, and the
  framework's own -- `not_found`, `invalid`, `too_large`, `internal` and the
  rest of `Refusal.Code.framework` -- need no listing. A code nobody
  declared is still answered, but logged as a bug, and `Spindle.Test.call`
  raises on it.
- **A name means one thing.** Two codes with the same name but a different
  status or doc are refused when the app is made.
- **A `401` code needs `~challenge`**, the `WWW-Authenticate` value, e.g.
  `~challenge:{|Bearer realm="api"|}`.
- **Your own wording for a bad body**:
  `Spindle.json ~refusal:(bad_body, "That is not an order.") order_json`.

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
- **Files** are `Form.file`, `file_opt` and `files`, each with a `filename`
  (text a person chose, never a path to trust), a `content_type` and the
  `content`. An upload too large to hold in memory is read with
  `Spindle.multipart` ([large bodies](dependencies.md#large-bodies)).

**No CSRF token is needed.** A cross-site `POST` is refused with `403
cross_origin` before any route sees it. Turning that check off removes your
forms' protection.

Next: [logging](logging.md).
