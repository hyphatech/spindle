# Bodies, answers and refusals

An API reads JSON, writes JSON, and says no -- and the three have to agree
with what the API's document claims, with what the client expects, and with
each other. Spindle makes each of them one declared value, so they cannot
drift apart.

## How it works

**One description reads and writes.** A record with
`[@@deriving wiretype]` gets a description, `<type>_json`, which decodes a
body, encodes an answer, and states its shape to the API's document and the
client's zod schema. Nothing is written twice. A shape the deriver cannot
describe is written by hand with
[`wiretype`'s combinators](https://github.com/hyphatech/wiretype#by-hand),
and is the same kind of value.

**The shape is the description's; a rule is yours.** The description checks
what the wire can state -- types, required members, bounds like
`[@min 1]` -- and a body that fails it never reaches your code: it is a `400`
with every problem at its place. What needs your data -- is the item in
stock, is the name taken -- is the endpoint's check, worded for a person.

**What a route returns is declared on it.** `Returns.json ~status:`Created
placed_json` says the route answers `201` with that shape, and the endpoint
returns the plain value; the framework encodes it, so the answer always is
what the route says.

**A refusal is a code, declared once.** A code has a name a client branches
on, a status, and what it means; a refusal made from it carries a sentence
for a person and, optionally, a detail that goes only to the log. A route
lists the codes it may give, so the API's document lists them too, and a
code a route never declared is caught by its tests.

## A body in, an answer out

An order is a record whose quantity has bounds; what was placed is another
record, answered at `201`; and an item that is sold out is a refusal the
application declares:

```ocaml
--8<-- "json_body.ml:app"
```

```sh
$ curl -i localhost:8080/orders -H 'content-type: application/json' \
    -d '{"item": "tea", "quantity": 2}'
HTTP/1.1 201 Created
content-type: application/json

{"number":1,"item":"tea","quantity":2}
```

A body of the wrong shape is answered before the endpoint runs, every
problem at once:

```sh
$ curl localhost:8080/orders -H 'content-type: application/json' \
    -d '{"quantity": "two"}'
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"body.quantity","code":"unexpected_type","message":"This must be a whole number, not text."},{"at":"body.item","code":"required","message":"This is required."}]}
$ curl localhost:8080/orders -H 'content-type: application/json' \
    -d '{"item": "tea", "quantity": 0}'
{"error":"invalid","message":"Some of that request is not what it should be.","problems":[{"at":"body.quantity","code":"too_small","message":"This must be at least 1."}]}
```

And the rule only the kitchen knows is the endpoint's own refusal:

```sh
$ curl -i localhost:8080/orders -H 'content-type: application/json' \
    -d '{"item": "cake", "quantity": 1}'
HTTP/1.1 409 Conflict
content-type: application/json

{"error":"sold_out","message":"There is no cake left today."}
```

??? example "The whole program"

    ```ocaml
    --8<-- "json_body.ml"
    ```

## What a route returns

A route is `Spindle.route meth path returns inputs`, and `Spindle.get`,
`post`, `put`, `patch` and `delete` are it with their method. What it
returns is a required argument, and it decides what its list of inputs
returns -- the plain value, or a refusal:

```ocaml
Spindle.get path Returns.html
  (let+ ... in Ok page)                                  (* a page, 200 *)

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

`Returns.text` is text at `200`; the status of a JSON value, and of
nothing, is the model's, one per route.

**A route whose success is one of several things** -- made or replaced,
queued or done -- lists the statuses it may answer, each with when, and
every branch returns the one it reached beside the value:

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

`Returns.empty_response` is the same with no body, the endpoint returning
`` Ok `Created `` or `` Ok `No_content ``. Every status shares the one body,
and the document gives each its own response and its sentence. A status is a
success: failing is a refusal, and a list that is empty, names a status twice
or names one that is not `2xx` is refused when the app is made. One the
endpoint answers that its list does not name is sent, logged as the route's
bug, and raised on by `Spindle.Test.call`, as a code nobody declared is.

## Responses, cookies and headers

`Returns` is the declaration on the route and `Response` is
the message on the wire: `Response` has `make` (a body as it is), `html`,
`json`, `empty` (`204`), `redirect`, `stream`, `events`, `takeover` and
`refusal`, for a route that makes its own; `Returns.websocket` is the one
model whose answer is a conversation.

**A cookie or a header the endpoint sets** arrives as an input that is a
function -- `Spindle.set_cookie`, `Spindle.add_header` -- which the endpoint
calls where it decides to, and a route that sets nothing never mentions:

```ocaml
let sign_out session set_cookie =
  Sessions.close session;
  set_cookie clear_session;
  Ok true

Spindle.post Path.(s "sign-out") (Returns.json Wiretype.bool)
  (let+ session = session and+ set_cookie = Spindle.set_cookie in
   sign_out session set_cookie)
```

What it set goes with an `Ok`, and never with a refusal, whose headers are
its own. Each request has its own; a call after the answer has gone, from a
fibre the endpoint left behind, changes nothing and is logged as the
route's bug. A test calls the endpoint with a function of its own. The content type, the length, the request id and
every cookie's attributes are written by the framework, and a header whose
value holds CR or LF is never written -- it would let whoever chose it write
headers of their own -- so the answer becomes `500`. So is every field that
says how an answer is framed or whether its connection lasts --
`Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Upgrade`,
`TE`, `Trailer`: a response that sets one itself, or answers a status that is
no final answer (200 to 599, `takeover`'s `101` aside), is the route's bug and
answers `500`, because a length beside the framework's is an answer a reader
can take two ways. An answer after which the connection should end is
`Response.close_connection`, and the server says `Connection: close` for it, once.
`takeover ~protocol`
answers `101` with that protocol in `Upgrade`, and hands the route the
connection's reader and writer until it returns, which is what a protocol
after HTTP is built on. RFC 9110 §7.8 lets a server switch only to a
protocol the client offered -- in its own `Upgrade`, with `Connection:
upgrade` -- and never an HTTP/1.0 client, so a takeover that does either is
the route's bug and answers `500` too, in-process and on the wire alike.

## Refusals and codes

An `Error` is always a `Refusal.t`, made from a **code**: a value declared
once with its status and what it means, so the two cannot disagree and every
code there is can be listed.

```ocaml
let conflict =
  Refusal.Code.make "conflict" ~status:`Conflict ~doc:"Somebody moved first."

Error (Refusal.make ~detail:(Store.error_to_string e) conflict
         "Somebody moved first.")
```

A route's codes are its `~refuses` and every one its inputs carry
(`Route.info`'s `codes`) -- `unsupported_media_type` among them, which a
body read as one type declares -- and the framework's own
(`Refusal.Code.framework`: `not_found`, `method_not_allowed`, `unreadable`,
`invalid`, `too_large`, `busy`, `cross_origin`, `not_implemented`,
`upgrade_required`, `internal`) need no declaring. A
refusal made from anything else is the route's bug: `Test.call` raises on it,
and the server logs a warning and answers it anyway. **A code means one
thing**: two declarations of one name with a different status, doc or
challenge are refused when the app is made, the framework's own included,
because a client branches on the name. A `401` code declares its challenge
(`~challenge`), which every refusal made from it carries in
`WWW-Authenticate`, because RFC 9110 §15.5.2 has every `401` say how to
authenticate; one declared without is refused with the rest. A credential
with no registered scheme -- a session cookie -- names a scheme of the
application's own. The framework's own refusals are sentences, and an
application that wants other words gives its own code and sentence, e.g.
`Spindle.json ~refusal:(bad_body, "That is not an order.") t`, which the
dependency then declares.

## Forms

A form's fields are typed inputs, read as a query's are, each at
`form.<name>` when it is wrong:

```ocaml
let email = Spindle.Form.required "email" Spindle.Codec.string
let remember = Spindle.Form.checked "remember"

Spindle.post Path.(s "sign-up") (Spindle.Returns.json account_json)
  (let+ email = email and+ remember = remember in
   sign_up ~email ~remember)
```

`Form.optional`, `required` and `list` take a codec, and `checked` is `true`
when a field was sent at all, since a box not ticked is not sent. The body
is read once, as `application/x-www-form-urlencoded` or, for a form with a
file in it, `multipart/form-data`, however many fields a route reads -- the
fields share it -- and held whole up to `max_body`; any other
`Content-Type` is `415` before it is read, and a field whose text is
not UTF-8 is a problem at its name. A form is one way to read a body, so a
route listing a field beside `Spindle.json` or a stream is refused when the
app is made. **A file** is `Form.file`, `file_opt` or `files`: its
`filename` -- text a person chose, never a path -- its type (`text/plain`
where the part names none) and its content; a file input left empty, which
a browser sends as a part with an empty name and nothing in it, is no file.
An upload too large to hold is `Spindle.multipart`'s
([a large body](dependencies.md#the-rules)). The
document describes the body as an object of the fields, each its codec's,
the required ones said.

**Forgery is the origin check's, and there is no token.** A browser posts a
form to another site without asking, which is why such a request is `403
cross_origin` before any route sees it; that is what a CSRF token was for,
and a form is read under the check and nothing else. An application that
turns the check off has turned off what protects its forms.

Next: [logging](logging.md).
