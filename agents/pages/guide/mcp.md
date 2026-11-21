# MCP servers

Give an agent tools to call, and resources to read. `spindle-mcp` serves the
[Model Context Protocol](https://modelcontextprotocol.io/specification/2026-07-28),
revision 2026-07-28, over HTTP: one `POST` endpoint, added to your routes as
[health checks](health.md) are.

```sh
opam install spindle-mcp
```

## A tool

```ocaml title="forecast_tool.ml"
(* The tool mcp serves: the weather for a city. *)

open Spindle.Syntax

type query = { city : string } [@@deriving wiretype]
type forecast = { city : string; celsius : int } [@@deriving wiretype]

(* What the tool reads: something the server holds, supplied as it starts. *)
let weather : (string -> int option) Spindle.Dep.t =
  Spindle.Dep.of_resource "weather"

let no_such_city =
  Spindle.Refusal.Code.make "no_such_city" ~status:`Not_found
    ~doc:"No forecast for that city."

let get_forecast =
  Spindle_mcp.tool "get_forecast" ~title:"Forecast"
    ~doc:"Today's temperature in a city, in degrees Celsius." query_json
    forecast_json
    (let+ weather = weather in
     fun (q : query) ->
       match weather q.city with
       | Some celsius -> Ok { city = q.city; celsius }
       | None ->
           Error (Spindle.Refusal.make no_such_city "There is no such city."))
```

A tool is a name, the description of its arguments, the description of its
result, and a [dependency](../tutorial/dependencies.md) giving the
function a call runs -- as a health check is a name and a dependency giving
the function a probe runs.

- The arguments' description is printed as the tool's `inputSchema`, and
  must be an object; the result's as its `outputSchema`. Nothing else
  states them.
- The function's `Ok` is the result: `structuredContent`, and its JSON as
  text beside it. Its `Error` is a result too, `isError`, with the
  refusal's sentence: the model reads it and can try again. So are
  arguments that do not read, with every problem named.
- `~title` is for a person, `~doc` for the model.

## Serving it

```ocaml title="mcp.ml"
(* An MCP server: one tool an agent calls, the weather for a city, added to
   the application's routes as health checks are. Point an MCP client at
   http://localhost:8080/mcp.

     curl -X POST localhost:8080/mcp \
       -H 'content-type: application/json' \
       -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: tools/list' \
       -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{
             "io.modelcontextprotocol/protocolVersion":"2026-07-28",
             "io.modelcontextprotocol/clientCapabilities":{}}}}' *)

let routes =
  Spindle_mcp.routes ~name:"weather" ~version:"1.0.0"
    [ Forecast_tool.get_forecast ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  let temperatures city = List.assoc_opt city [ ("Paris", 18); ("Oslo", 4) ] in
  Spindle.serve env
    ~resources:[ Spindle.Dep.resource Forecast_tool.weather temperatures ]
    routes
```

`Spindle_mcp.routes` is `POST /mcp` (or `~path`), serving
`server/discover`, `tools/list` and `tools/call` -- and, given
[resources](#resources) and [`~changes`](#watching-a-resource), the methods
that read and watch them:

```console
$ curl -X POST localhost:8080/mcp -H 'content-type: application/json' \
    -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: tools/call' \
    -H 'mcp-name: get_forecast' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_forecast",
         "arguments":{"city":"Paris"},"_meta":{"io.modelcontextprotocol/protocolVersion":
         "2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","content":[{"type":"text",
"text":"{\"city\":\"Paris\",\"celsius\":18}"}],"structuredContent":{"city":"Paris",
"celsius":18},"isError":false,"_meta":{"io.modelcontextprotocol/serverInfo":
{"name":"weather","version":"1.0.0"}}}}
```

Every tool's dependency is read on every call, as every health check's is on
every probe, so the endpoint reads the same on every request: what it reads
is listed, the resources its tools read are checked as the server starts,
and a server missing one does not start. So:

- **A tool's dependency hands over what the server holds** -- a pool, a
  client -- and its function does the work.
- **A tool's dependency's refusal is that tool's alone.** One that refuses --
  nobody signed in, for a tool that reads the caller -- is that tool's error,
  `isError` with the refusal's sentence, when it is called, and every other
  tool is called as before.
- **What refuses for the whole endpoint is `~guard`**, read first, its
  refusal the answer to every request:

  ```ocaml
  Spindle_mcp.routes ~name ~version
    ~guard:(Spindle.Rate.limit calls ~key:Spindle.client_ip)
    tools
  ```

## Progress, and a caller that left

A tool that takes a while tells the caller how far it has come, and stops
when nobody is waiting any more:

```ocaml
let export =
  Spindle_mcp.tool "export" query_json report_json
    (let+ db = Db.pool
     and+ call = Spindle_mcp.call
     and+ gone = Spindle.client_gone in
     fun query ->
       Export.run db query
         ~progress:(fun n total -> Spindle_mcp.progress call ~total n)
         ~stop:gone)
```

- `Spindle_mcp.call` is this call, read as `Spindle.now` is.
  `Spindle_mcp.progress call n` reports `n`, of `~total` where it is known,
  with a `~message` for a person.
- A client that asked for progress is answered as an event stream: each
  report as it is made, then the result. One that did not is answered as
  before, and the reports are dropped, so the tool is written once.
- A report not above the last is dropped, as MCP has each one larger.
- A client that cancels closes the stream. `Spindle.client_gone` resolves
  once the server learns it -- at the first report it cannot write -- and
  the tool stops where it can: nothing cuts it off mid-write.

## Asking before acting

A tool that deletes, pays or sends asks the person first:

```ocaml
type confirm = { ok : bool } [@@deriving wiretype]

let sure =
  Spindle_mcp.Question.form "confirm"
    ~message:"Delete the folder and all it holds?" confirm_json

let delete =
  Spindle_mcp.tool "delete_folder" ~asks:[ Spindle_mcp.Question.declare sure ]
    folder_json Wiretype.string
    (let+ db = Db.pool and+ call = Spindle_mcp.call in
     fun folder ->
       match Spindle_mcp.answer call sure with
       | Accept { ok = true } -> Folder.delete db folder
       | Accept _ | Decline | Cancel -> Ok "Nothing was deleted.")
```

- A question is a form: an object of strings, numbers, integers, booleans
  and enums, which the client shows the person. `Spindle_mcp.routes`
  raises `Invalid_argument` for any other.
- A tool's questions are asked before its function runs. A call without
  their answers is answered "input required", every question at once; the
  client asks the person and calls again with the answers, as MCP
  2026-07-28 has it. So the function always has its answers:
  `Accept` what they filled in, `Decline`, or `Cancel` if they dismissed it.
- A client that cannot show a form is told so before anything runs.
- Claude Code shows the question, and calls again with your answer.

## Tokens and scopes

With `~auth`, every call needs an [OAuth bearer token](oauth.md),
and a tool may need a scope:

```ocaml
let forecast =
  Spindle_mcp.tool "get_forecast" ~scope:"weather:read" query_json
    forecast_json (...)

let routes =
  let served = Spindle_mcp.routes ~auth ~name ~version [ forecast ] in
  served @ [ Spindle.Bearer.metadata auth served ]
```

- `tools/list` names only the tools the token grants, so a model is never
  shown one it cannot call; a call of one it lacks is a `403`
  `insufficient_scope` naming the scope, so the client can ask for it.
- The metadata document names every tool's and resource's scope in
  `scopes_supported`.

## Who may do what

A scope says what the *client* may do. Which notes the *person* behind the
token may delete is a [policy's](access.md), checked in the
tool as in a route. A tool's arguments name the object, so it is judged by
`Access.check`:

```ocaml
let delete_note =
  Spindle_mcp.tool "delete_note" note_ref Wiretype.string
    (let+ checked = Spindle.Access.check notes and+ db = conn in
     fun r ->
       let* note = find db r.id in
       let* note = checked Delete note in
       remove db note)
```

- The caller is the person the token was issued for -- your `principal`
  reads its subject -- never the client calling for them, so an agent may do
  what its person may and nothing more.
- A denial is the tool's error, which the model reads, and is logged as a
  route's is.
- Every tool's dependency is read on every call, and one that refuses --
  nobody signed in, for a tool that reads the caller -- is that tool's error
  when it is called, and no other tool's.

## Resources

A tool is something a client asks the server to do; a resource is something
it reads -- a file, a record, a log. A resource is a URI, a name and a
dependency giving the function that reads it; a template is every resource
whose URI it matches, its variables handed to the function:

```ocaml title="journal.ml"
(* The resource mcp_journal serves: a journal an intent, numbered lines from 1,
   appended and never changed, read from a line on. *)

open Spindle.Syntax

type t = { lock : Eio.Mutex.t; journals : (string, string list) Hashtbl.t }
(* each journal newest line first *)

let create () = { lock = Eio.Mutex.create (); journals = Hashtbl.create 16 }

let append t id line =
  Eio.Mutex.use_rw ~protect:true t.lock (fun () ->
      let lines = Option.value (Hashtbl.find_opt t.journals id) ~default:[] in
      Hashtbl.replace t.journals id (line :: lines))

(* The lines from [from] on, oldest first; [None] for a journal never begun. *)
let lines t id ~from =
  Eio.Mutex.use_ro t.lock (fun () ->
      Option.map
        (fun newest_first ->
          List.filteri (fun i _ -> i + 1 >= from) (List.rev newest_first))
        (Hashtbl.find_opt t.journals id))

let begun t id = Eio.Mutex.use_ro t.lock (fun () -> Hashtbl.mem t.journals id)

(* What the template reads: the journals, which the server holds. *)
let journals : t Spindle.Dep.t = Spindle.Dep.of_resource "journals"

(* A line a content, so a reader counts what it was given. A read with no
   [from] answers no line: it is what a listen makes to check a caller may
   read the journal, and should cost nothing. *)
let journal =
  Spindle_mcp.template "haf://intents/{id}/journal{?from}" ~name:"journal"
    ~doc:"An intent's journal, one JSON event a line, from line [from] on."
    ~mime:"application/json" ~ttl_ms:0
    Spindle_mcp.Template.(
      let+ id = required "id" Wiretype.string
      and+ from = optional "from" (Wiretype.int_bounded ~min:1 ()) in
      (id, from))
    (let+ journals = journals in
     fun (id, from) ->
       match from with
       | None ->
           if begun journals id then Ok [] else Error Spindle.Refusal.not_found
       | Some from -> (
           match lines journals id ~from with
           | Some lines -> Ok (List.map (fun l -> Spindle_mcp.Text l) lines)
           | None -> Error Spindle.Refusal.not_found))
```

```ocaml title="mcp_journal.ml"
(* An MCP server of resources: a journal an intent, offered as a template a
   client reads from a line on, and told to a client watching it as each line
   is written.

     curl -X POST localhost:8080/mcp \
       -H 'content-type: application/json' \
       -H 'mcp-protocol-version: 2026-07-28' -H 'mcp-method: resources/read' \
       -H 'mcp-name: haf://intents/0197/journal?from=1' \
       -d '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{
             "uri":"haf://intents/0197/journal?from=1","_meta":{
             "io.modelcontextprotocol/protocolVersion":"2026-07-28",
             "io.modelcontextprotocol/clientCapabilities":{}}}}' *)

let id = "0197"
let uri = "haf://intents/" ^ id ^ "/journal"

(* A line a second, each told to whoever watches the journal. *)
let rec write ~clock journals changes n =
  Journal.append journals id (Printf.sprintf {|{"event":"tick","n":%d}|} n);
  Spindle_mcp.Changes.updated changes uri;
  Eio.Time.Mono.sleep_span clock Mtime.Span.(1 * s);
  write ~clock journals changes (n + 1)

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  let journals = Journal.create ()
  and changes = Spindle_mcp.Changes.create () in
  let routes =
    Spindle_mcp.routes ~name:"haf" ~version:"1.0.0"
      ~resources:[ Journal.journal ] ~changes []
  in
  (* A listen never ends on its own: a server that is stopping ends each,
     gracefully, so its client knows not to listen again. *)
  Eio.Fiber.first
    (fun () -> write ~clock:(Eio.Stdenv.mono_clock env) journals changes 1)
    (fun () ->
      Spindle.serve env
        ~resources:[ Spindle.Dep.resource Journal.journals journals ]
        ~on_stop:(fun () -> Spindle_mcp.Changes.close changes)
        routes)
```

- `Spindle_mcp.resource uri ~name f` is one resource, listed by
  `resources/list`. `Spindle_mcp.template text ~name variables f` is a
  template, listed by `resources/templates/list`. Both are read by
  `resources/read`, and given to `routes` as `~resources`.
- A template is the part of RFC 6570 that reads back from a URI one way:
  `{name}`, one segment, never across a `/`, and a form-style query last,
  `{?from,to}`, each of whose variables may be left out. `routes` raises
  `Invalid_argument` for any other expression.
- Each variable is read by its own description, as a query parameter is:
  `Template.required` for one every URI holds, `Template.optional` for a
  query's that may be absent. A URI whose variables do not read is
  `-32602`, naming each problem.
- The function answers its contents: `Text` as it is, or `Blob` bytes, sent
  as base64, each with the URI read and the resource's `~mime`.
- `~ttl_ms` is how long a client may keep what it read, in place of
  `routes`' `~ttl_ms`; something that changes as it is watched is `0`.
- `~scope` is as a tool's: a resource the token does not grant is left out
  of the lists, and its read is a `403` naming the scope.

**A read tells a caller nothing of an object they may not see.** A function
that answers `Refusal.not_found`, or `Access.forbidden` for someone else's
object -- what [`Access.can`](access.md) answers, unless told
otherwise -- is the resource not found, `-32602`, word for word what a URI
no resource has is told. Any other `Error` of the function is `-32603`, its
sentence; a refusal of the resource's dependency -- a rate limit, a caller
not signed in -- is that refusal, its status and headers.

## Watching a resource

A client that shows a journal as it grows does not poll it. It opens
`subscriptions/listen`, naming the URIs it watches, and the server tells it
each time one changes -- "read it again", never what changed. The server in
`mcp_journal.ml` above does this: `Spindle_mcp.Changes.create ()` is the hub,
given to `routes` as `~changes`, and `Changes.updated changes uri` says a
URI changed, from wherever the change is made.

- A listen is one request, answered as an event stream that stays open: the
  acknowledgment first, naming the URIs it watches, then one
  `notifications/resources/updated` a change. While it is open the hub lists
  it, and once it ends nothing of it is kept, so the server keeps no session.
- **A listen reveals nothing a read would not.** It watches a URI only where
  `resources/read` would answer it for this caller -- its scope granted and
  its function answering it, run once as the listen opens -- and leaves any
  other out of its acknowledgment, without an error. So the check costs one
  read a URI, each time a listen opens: a resource that is large should
  answer a read with nothing to read cheaply, as `journal.ml`'s does with no
  `from`. A listen watches at most 64 URIs.
- **It is subscribed before it is acknowledged**, so a change made the
  instant after reaches it. A client that reads after the acknowledgment,
  from its own place, and again on each change, misses nothing.
- **It ends three ways.** A client that closes it is gone, and nothing more
  is sent. `Changes.close`, from `Spindle.serve`'s `~on_stop`, ends every
  listen with the graceful result, which tells its client the server ended
  it. A listen more than `~depth` (16) changes behind is dropped with no
  result: its client listens again and reads from where it was, and loses
  nothing, since a change says only "read it again".
- No list's changes are watched: the tools and resources a server serves
  are fixed when it starts.

## What a client is told

The server speaks 2026-07-28 alone, and answers as that revision says:

| | Answer |
|---|---|
| A body that is no JSON | `400`, `-32700` |
| A batch, a `null` id, a response | `400`, `-32600` |
| `MCP-Protocol-Version`, `Mcp-Method` or `Mcp-Name` missing or not the body's | `400`, `-32020` |
| Another version, or a legacy client's `initialize` | `400`, `-32022`, naming 2026-07-28 |
| `_meta` without the version or the client's capabilities | `400`, `-32602` |
| A method it does not serve | `404`, `-32601` |
| An unknown tool | `-32602` |
| A URI no resource has, or one its function will not show this caller | `-32602`, naming the URI |
| A resource method, on a server given no resources | `404`, `-32601` |
| `subscriptions/listen`, on a server given no `~changes` | `404`, `-32601` |
| `subscriptions/listen` with no `notifications` | `-32602` |
| A notification | `202`, no body |
| A request from another site's page | `403`, the application's [forgery check](cookies.md#csrf-and-cors) |
| `GET` | `405` |

The server keeps nothing between requests: 2026-07-28 has no session, and
each call is answered on its own, on whichever domain or instance takes it.
The one thing that outlives a request is the application's
`Spindle_mcp.Changes`, which lists a listen only while it is open; it is one
process's, so behind a balancer of several instances, a change one makes
reaches only the listens it holds.

## Calling another server's tools

`spindle-mcp-client` calls an MCP server's tools, and reads and watches its
resources, from any Eio program, on the
[HTTP client](client.md) alone: a program that only calls
another server installs and links no framework.

```sh
opam install spindle-mcp-client
```

```ocaml
(* Calling another server's tools: the weather server of mcp.ml, run
   beside this one. It links spindle-client and no framework.

     dune exec examples/mcp.exe &
     dune exec examples/mcp_client.exe *)

type query = { city : string } [@@deriving wiretype]
type forecast = { city : string; celsius : int } [@@deriving wiretype]

let () =
  Eio_main.run @@ fun env ->
  Spindle_client.run env @@ fun client ->
  let weather =
    Spindle_mcp_client.create client ~url:"http://localhost:8080/mcp"
  in
  match Spindle_mcp_client.tools weather with
  | Error e -> prerr_endline (Spindle_mcp_client.error_to_string e)
  | Ok tools -> (
      List.iter
        (fun (t : Spindle_mcp_client.tool) -> print_endline t.name)
        tools;
      match
        Spindle_mcp_client.call weather "get_forecast" query_json
          { city = "Paris" } forecast_json
      with
      | Ok f -> Printf.printf "%s: %d°C\n" f.city f.celsius
      | Error e -> prerr_endline (Spindle_mcp_client.error_to_string e))
```

- `create client ~url` names the server and does no I/O. `~headers` go with
  every call, a bearer token among them.
- `tools` lists every page of the server's tools. `call` writes the
  arguments by one description and reads `structuredContent` by another;
  `call_value` takes and gives JSON, for a program passing a model's
  arguments through.
- A tool's own failure is `` `Tool_failed `` with its text; a server's
  refusal is `` `Refused `` with its status and JSON-RPC code.
- `call ~progress:f` asks the server for progress and hands `f` each
  report as it arrives. A caller that stops waiting cancels its fiber, which
  closes the connection: that is how a call is cancelled over HTTP.
- A server that needs a token is signed in to with `~oauth`, a
  [`Spindle_client.Oauth`](oauth.md#signing-in-as-a-client):
  a `401` opens the browser for a person to sign in, and the call is
  retried with the token, which is kept for the next.
- A server may ask a question in the middle of a call. Give `~elicit` a
  function that answers it -- a person, a form, a policy -- and the call is
  retried with the answer; without one, the client tells servers it answers
  none, and a call that asks anyway is `` `Unanswered ``.
- Every request carries the headers 2026-07-28 asks for, an argument a
  listed tool annotates with `x-mcp-header` among them, and an answer is read
  as one JSON object or an event stream, whichever the server sends.

### Reading its resources

```ocaml
let* resources = Spindle_mcp_client.resources haf in
let* templates = Spindle_mcp_client.templates haf in
let* contents = Spindle_mcp_client.read haf "haf://intents/0197/journal?from=1" in
...
```

- `resources` and `templates` list every page of the server's resources and
  templates, each with its name, title, description and MIME type.
- `read uri` answers the contents: `Text`, or `Blob` bytes, decoded from
  base64, each with its URI and type. A URI the server has no resource at is
  `` `Refused `` with the code `-32602`. Expanding a template into a URI is
  the caller's: the server says what its variables mean.

### Watching a resource

```ocaml title="mcp_watch.ml"
(* Watching a journal as it grows: run mcp_journal, then this, which prints
   each line once, in order, and carries on after a dropped listen without
   losing one. *)

let uri = "haf://intents/0197/journal"

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_client.run env @@ fun client ->
  let clock = Eio.Stdenv.mono_clock env in
  let mcp = Spindle_mcp_client.create client ~url:"http://localhost:8080/mcp" in
  (* The client's own place is the cursor: the next line it has not read. *)
  let next = ref 1 in
  let catch_up () =
    match
      Spindle_mcp_client.read mcp (Printf.sprintf "%s?from=%d" uri !next)
    with
    | Ok contents ->
        List.iter
          (fun (c : Spindle_mcp_client.content) ->
            match c.data with
            | Text line ->
                print_endline line;
                incr next
            | Blob _ -> ())
          contents
    | Error e -> prerr_endline (Spindle_mcp_client.error_to_string e)
  in
  (* Read once acknowledged, so a line written since is not missed, and again
     on each change; a listen dropped is listened again, a second on. *)
  let rec watch () =
    match
      Spindle_mcp_client.listen mcp [ uri ] (fun _ ->
          catch_up ();
          `Continue)
    with
    | Ok (Dropped _) ->
        Eio.Time.Mono.sleep_span clock Mtime.Span.(1 * s);
        watch ()
    | Ok (Completed | Stopped) -> ()
    | Error e -> prerr_endline (Spindle_mcp_client.error_to_string e)
  in
  watch ()
```

- `listen uris f` opens `subscriptions/listen` and hands `f` each
  notification as it arrives: `Acknowledged` first, naming the URIs the
  server watches -- one it left out it will never tell of -- then `Updated`
  for each change. It runs in the caller's fiber until the listen ends or `f`
  answers `` `Stop ``.
- **The client's place is the cursor.** A change is "read it again", so the
  watcher reads from the next line it has not seen, once acknowledged and on
  each change. A change made after the acknowledgment is always told, so
  nothing written in between is missed, and several changes read once are
  as good as each read alone.
- It ends `Stopped` when `f` stopped it, `Completed` when the server ended
  it -- it has nothing more to say, and the watcher stops too -- or
  `Dropped` when the stream ended without that: the connection lost, the
  listen dropped for falling behind, or no word for `~read_timeout` (60 s).
  The watcher listens again and reads from where it was, and loses nothing.
  It never listens again by itself: whether to, and how long to wait first,
  are the caller's.
- An error is a listen refused or never acknowledged, as any request's is.

## Testing

`Spindle_mcp.Test.call` sends a request as a client would -- the JSON-RPC
envelope, the `_meta` and the headers -- to an app made with
`Spindle.Test.app`:

```ocaml
let r =
  Spindle_mcp.Test.call app "tools/call"
    [ ("name", String "get_forecast"); ("arguments", Object [ ("city", String "Paris") ]) ]
```

`Spindle_mcp.Test.events` sends the same, and reads the answer a message at
a time, for a `subscriptions/listen`: its function is handed each event as
it arrives and answers `` `Stop `` to leave.
