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

val routes :
  ?path:Spindle.Path.path ->
  ?guard:unit Spindle.Dep.t ->
  ?auth:Spindle.Bearer.t ->
  ?instructions:string ->
  ?ttl_ms:int ->
  name:string ->
  version:string ->
  tool list ->
  Spindle.Route.t list
(** [POST /mcp], or [path]: [server/discover], [tools/list] and [tools/call].
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
    no form (an object of strings, numbers, integers, booleans and enums), two
    questions of one key on a tool, or a tool whose dependency may refuse
    ({!Spindle.Dep.codes}): every one is read on every call, so one that refused
    would refuse every call. Each is a constant written in source. *)

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
end
