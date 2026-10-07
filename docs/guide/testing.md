# Testing

```ocaml
let app = Spindle.Test.app routes in
let r = Spindle.Test.call app `POST "/echo" ~now:1_000 ~body:{|{"text":"hi"}|} in
Alcotest.(check int) "status" 200 r.status;
Alcotest.(check (option string)) "id" (Some "…") (Spindle.Test.header r "x-request-id")
```

In-process, no socket, a clock the test sets; cookies are written as the server
would write them. `Spindle.Test.app` is `App.make` for a test, raising on a
route table it refuses as `Spindle.serve` does, since a table is a constant
written in source. The status and headers are the ones the server writes --
one function renders both -- save `connection`. A stream is run to its end.
A refusal whose code its route does not declare raises `Invalid_argument`,
so the test that reaches it names the route's bug. `Spindle.Server.serve_on` serves an app on a socket of the test's own, through
the same loop as `run`, when the wire itself is under test.

**A flow of calls** is a `Test.browser`, which keeps what the app set as a
browser does -- by name and path, dropped by an empty value or an age past
the call's `now`, sent to every call under a cookie's path -- so a test signs
in, calls what needs the session and signs out:

```ocaml
let b = Spindle.Test.browser app in
let _ = Spindle.Test.Browser.call b `POST "/sign-in" ~body in
let me = Spindle.Test.Browser.call b `GET "/me" in ...
```

**A stream that never ends** is read by `Test.events`, each event -- its
name, data and id, as a client reads it -- handed to a function that answers
`` `Continue `` or `` `Stop ``. Stopping is the client going: the route's
next `send` is `Error Gone`, and a producer waiting for something to send is
cancelled rather than waited on. It runs inside `Eio_main.run`, as
`Test.websocket` does.
