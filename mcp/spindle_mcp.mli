(** A Model Context Protocol server: the routes an agent calls tools through,
    added to the application's own, as {!Spindle.Health.routes} are.

    {[
    let forecast =
      Spindle_mcp.tool "get_forecast" ~scope:"weather:read" query_json
        forecast_json
        (let+ db = Db.pool in
         fun query -> Forecast.find db query)

    let routes =
      app_routes
      @ Spindle_mcp.routes ~name:"weather" ~version:"1.0.0" ~auth [ forecast ]
    ]}

    It speaks MCP 2026-07-28 over Streamable HTTP, and nothing earlier: one
    [POST] endpoint, each message answered on its own, no session kept. A tool
    is a name, the descriptions of its arguments and its result, and a
    dependency giving the function a call runs -- as a health check is a name
    and a dependency giving the function a probe runs. Every tool's dependency
    is read on every call, as [/readyz] reads every check's, so the route reads
    the same on every request: what it reads is listed, the resources its tools
    read are checked as the server starts, and its refusals are declared. A
    tool's dependency hands over what the server holds -- a pool, a client --
    and its function does the work. *)

type tool
(** One tool an agent may call. *)

(** A question a tool asks a person before it acts -- "Delete the folder and all
    it holds?" -- through the client, which shows it as a form (MCP's
    elicitation). *)
module Question : sig
  type 'a t

  val form : string -> message:string -> 'a Wiretype.t -> 'a t
  (** [form key ~message answer]: [message] for the person, [answer] what they
      fill in -- an object whose members are strings, numbers, integers,
      booleans or enums, as a form holds ({!routes} refuses any other). [key]
      names it among a tool's questions. *)

  type declared
  (** A question of any answer, as a tool lists them. *)

  val declare : 'a t -> declared
end

type 'a reply =
  | Accept of 'a  (** what the person filled in *)
  | Decline  (** they said no *)
  | Cancel  (** they dismissed it, choosing nothing *)

val tool :
  ?title:string ->
  ?doc:string ->
  ?scope:string ->
  ?asks:Question.declared list ->
  string ->
  'a Wiretype.t ->
  'r Wiretype.t ->
  ('a -> ('r, Spindle.Refusal.t) result) Spindle.Dep.t ->
  tool
(** [tool name arguments result f]: [arguments] is read from a call, and printed
    as the tool's [inputSchema], an object; [result] is what [f] answers, as
    [structuredContent] and the JSON text beside it, and printed as its
    [outputSchema]. [f] gives the function a call runs. Arguments that do not
    read, and an [Error] it answers, are a tool result the model reads,
    [isError], with every problem or the refusal's sentence -- never a refusal
    of the request. [title] is for a person, [doc] for the model.

    [scope] is what the bearer token must grant: a tool the token does not is
    left out of [tools/list], and a call of it is refused [insufficient_scope],
    [403] ({!Spindle.Bearer.scope}'s answer). It needs {!routes}'s [auth]. *)

(** {1 The call} *)

type call
(** What belongs to one call of a tool, beside its arguments. *)

val answer : call -> 'a Question.t -> 'a reply
(** The person's answer to a question the tool asks ([~asks]), which every call
    of the tool has before its function runs; a question the tool does not ask
    reads as [Cancel], as one never put. *)

val call : call Spindle.Dep.t
(** This call, read by a tool's dependency as {!Spindle.now} is: the same value
    for every tool, read once. It refuses nothing. *)

val progress : call -> ?total:float -> ?message:string -> float -> unit
(** [progress call done_]: how far the call has come, of [total] where it is
    known, [message] for a person. Where the client asked for progress (a
    [progressToken]), the call is answered as an event stream, each report a
    [notifications/progress] before the result; where it did not, a report is
    dropped, so a tool reports the same either way. A report not above the last
    is dropped too, as the specification has each one larger. A tool that should
    stop when its caller has gone reads {!Spindle.client_gone} beside it. *)

(** {1 Resources} *)

type resource
(** One resource a client may read, or one template of them. *)

(** What a read answers: a resource's contents, each sent with the URI read and
    the resource's MIME type. *)
type content = Text of string | Blob of string  (** bytes, sent as base64 *)

val resource :
  ?title:string ->
  ?doc:string ->
  ?mime:string ->
  ?scope:string ->
  ?ttl_ms:int ->
  string ->
  name:string ->
  (unit -> (content list, Spindle.Refusal.t) result) Spindle.Dep.t ->
  resource
(** [resource uri ~name f]: the resource at [uri], listed in [resources/list]
    with its [name], its [title] for a person, its [doc] for a model and its
    [mime] type; [f] gives the function [resources/read] runs. [ttl_ms] is how
    long a client may keep what it read, in place of {!routes}'s; a resource
    that changes as it is watched -- a log's tail -- is [0].

    An [Error] the function answers of {!Spindle.Refusal.not_found}, or of
    {!Spindle.Access.forbidden} -- someone else's object -- is the resource not
    found, [-32602], so a read tells a caller no more of an object they may not
    see than one that does not exist; any other is [-32603], its sentence. A
    resource that exists and holds nothing answers [Ok []]. [scope] is as a
    tool's. *)

(** The variables of a {!template}, each read from the text the URI holds by its
    own description, as a query parameter is ([Wiretype.of_text]).

    {[
    Spindle_mcp.Template.(
      let+ id = required "id" Wiretype.string
      and+ from = optional "from" (Wiretype.int_bounded ~min:1 ()) in
      (id, from))
    ]} *)
module Template : sig
  type 'a t

  val required : string -> 'a Wiretype.t -> 'a t
  (** A variable every URI holds: a path's [{name}], or a query's that is never
      left out. *)

  val optional : string -> 'a Wiretype.t -> 'a option t
  (** A query's variable a URI may leave out. *)

  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
end

val template :
  ?title:string ->
  ?doc:string ->
  ?mime:string ->
  ?scope:string ->
  ?ttl_ms:int ->
  string ->
  name:string ->
  'v Template.t ->
  ('v -> (content list, Spindle.Refusal.t) result) Spindle.Dep.t ->
  resource
(** [template uri_template ~name variables f]: every resource whose URI
    [uri_template] matches, listed in [resources/templates/list]; a read of one
    hands [f]'s function the [variables] read from it. A URI whose variables do
    not read is [-32602], naming each problem. The rest is {!val-resource}'s.

    A template is the part of RFC 6570 that reads back from a URI one way, since
    RFC 6570 defines expansion and a template of its higher levels can expand
    two ways to one URI: [{name}], level 1, matching one or more characters up
    to the next literal of the template, never [/], [?] or [#], percent-decoded;
    and [{?name,name}], level 3's form-style query, last, read as
    [application/x-www-form-urlencoded], each variable of it free to be absent
    and a member it does not name ignored.

    {[
    Spindle_mcp.template "haf://intents/{id}/journal{?from}" ~name:"journal"
      ~mime:"application/jsonl" ~ttl_ms:0 journal_variables
      (let+ intents = Intents.dep in
       fun (id, from) -> Intents.journal intents id ~from)
    ]} *)

(** {1 Watching} *)

(** What the application tells the server changed, so every client listening to
    it hears: the one value of the server's that outlives a request.

    {[
    let changes =
      Spindle_mcp.Changes.create ()
        (* as a journal grows *)
        Spindle_mcp.Changes.updated changes "haf://intents/0197/journal"
    ]}

    A client opens [subscriptions/listen] naming the URIs it watches, and is
    told [notifications/resources/updated] for each change to one of them, as
    the change is made -- "read it again", never what changed, so a client that
    missed one reads what it holds. A listen is one request held open: while it
    is open, the hub lists it, and once it ends it is gone, so the server keeps
    nothing of a client between requests. A listen that cannot keep up --
    [depth] changes it has not been sent -- is dropped, ending with no result,
    and its client listens again and reads from where it was. *)
module Changes : sig
  type t

  val create : ?depth:int -> unit -> t
  (** [depth] (16) is how many changes a listen may fall behind before it is
      dropped. Raises [Invalid_argument] for a depth below one, as
      {!Spindle.Broadcast.create} does. *)

  val updated : t -> string -> unit
  (** [updated t uri]: [uri] changed. Every listen that watches it is told, and
      nothing waits: one that cannot keep up is dropped. *)

  val watched : t -> string list
  (** The URIs some open listen watches. *)

  val close : t -> unit
  (** Ends every listen, each with the graceful result, which tells its client
      the server ended it: what a server that is stopping calls, in
      {!Spindle.Server.run}'s [on_stop], since a listen never ends on its own.
  *)
end

val routes :
  ?path:Spindle.Path.path ->
  ?guard:unit Spindle.Dep.t ->
  ?auth:Spindle.Bearer.t ->
  ?instructions:string ->
  ?ttl_ms:int ->
  ?resources:resource list ->
  ?changes:Changes.t ->
  name:string ->
  version:string ->
  tool list ->
  Spindle.Route.t list
(** [POST /mcp], or [path]: [server/discover], [tools/list] and [tools/call],
    and with [resources], [resources/list], [resources/templates/list] and
    [resources/read], [resources] among the capabilities [server/discover]
    names. A URI is read by the first of the [resources] given whose URI is it,
    then of their templates, in order; one none matches is [-32602].

    With [changes], [subscriptions/listen] too, and [subscribe] among the
    [resources] capability: an event stream, its first message
    [notifications/subscriptions/acknowledged], then a
    [notifications/resources/updated] for each change {!Changes.updated} is told
    of to a URI it acknowledged, each carrying the listen's id as its
    [subscriptionId]. A listen watches a URI only where [resources/read] would
    answer it for this caller -- a resource or template matches it, its
    variables read, the token grants its scope and its function answers it, run
    once as the listen opens -- and leaves any other out of its acknowledgment,
    never an error, so a listen reveals nothing a read would not; and at most 64
    URIs a listen. It is subscribed to every one before it is acknowledged, so a
    change made the instant after reaches it. It watches no list's changes,
    since what is served is fixed when the server starts. It ends silently when
    its client goes; with the graceful result when {!Changes.close} ends it;
    with none when it was dropped as slow; and at once, with the result, when it
    watches nothing. Without [changes], [subscriptions/listen] is a method not
    served.

    [name] and [version] are the server's, sent as [serverInfo] in every result;
    [instructions] tells a model how to use the server, in [server/discover].
    [ttl_ms] (300000) is how long a client may keep a list or a discovery
    ([ttlMs]); they are [private] to the token where [auth] is given, since the
    tools listed are the token's, and [public] otherwise.

    [auth] makes every call need a bearer token ({!Spindle.Bearer.val-claims}),
    and lists every tool's scope on the route's credential, so
    {!Spindle.Bearer.metadata} names them. [guard] is read first and its refusal
    is the answer: a rate limit for the whole endpoint, say.

    A request is answered as MCP 2026-07-28 says: a [MCP-Protocol-Version],
    [Mcp-Method] or [Mcp-Name] header missing or disagreeing with the body,
    [400] [-32020]; a version other than 2026-07-28, [400] [-32022] naming the
    one supported; a request's [_meta] without its version and capabilities,
    [400] [-32602]; a method it does not serve, [404] [-32601]; a body that is
    no JSON, [400] [-32700], and a batch, a [null] id or a response, [400]
    [-32600]; an unknown tool, [-32602]; a notification, [202]. A request from
    another site's page is refused [403] by the application's forgery check
    ({!Spindle.App.make}), which MCP asks of every server against DNS rebinding.

    A tool's questions ([~asks]) are asked before its function runs: a call
    without an answer to each, or with one that does not read, is answered
    [input_required], every such question in one round, and the client calls
    again with the answers (MCP's multi round-trip requests); a client that
    declared no form elicitation is answered [400] [-32021] before anything
    runs.

    Raises [Invalid_argument] for two tools of one name, a name MCP refuses
    (outside [A-Za-z0-9_.-], or longer than 128), arguments whose description is
    no object, a tool with a [scope] and no [auth], a question whose answer is
    no form (an object of strings, numbers, integers, booleans and enums), or
    two questions of one key on a tool; and for a template outside the part of
    RFC 6570 read here, two variables side by side, a variable it names that its
    {!Template} does not read or one read that it does not name, two resources
    of one URI or two templates of one text, or a resource with a [scope] and no
    [auth]. Each is a constant written in source.

    Every tool's and resource's dependency is read on every call, through
    {!Spindle.Dep.attempt}: one that refuses -- a caller who is not signed in,
    for a tool that reads one -- is that tool's error, [isError] with the
    refusal's sentence, when it is called, and no other tool's; a resource's is
    that resource's answer when it is read -- not found, as its function's, or
    else the refusal itself, its status and headers -- and no other's. *)

(** Calling the routes in a test, as a client would: the JSON-RPC envelope, the
    [_meta] and the headers MCP asks for, written for the test. *)
module Test : sig
  val call :
    ?now:Ptime.t ->
    ?progress_token:string ->
    ?path:string ->
    ?headers:(string * string) list ->
    ?capabilities:Wiretype.Value.t ->
    Spindle.App.instance ->
    string ->
    (string * Wiretype.Value.t) list ->
    Spindle.Test.response
  (** [call app meth params]: a request of id [1] to [/mcp], or [path], with
      [params] and a [_meta] naming 2026-07-28 and [capabilities] (none), the
      headers matching it, and [progress_token] in the [_meta] where given.
      [headers] are added after them, and [now] is {!Spindle.Test.call}'s. *)

  val events :
    ?now:Ptime.t ->
    ?path:string ->
    ?headers:(string * string) list ->
    ?capabilities:Wiretype.Value.t ->
    Spindle.App.instance ->
    string ->
    (string * Wiretype.Value.t) list ->
    (Spindle_http.Event_stream.event -> [ `Continue | `Stop ]) ->
    (unit, Spindle.Test.response) result
  (** [events app meth params f]: the request {!val-call} sends, its answer read
      as an event stream by {!Spindle.Test.events} -- a [subscriptions/listen],
      read a message at a time and left when [f] answers [`Stop]. *)
end
