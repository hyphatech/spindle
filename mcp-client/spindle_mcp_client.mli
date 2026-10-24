(** Calling another server's tools over the Model Context Protocol, 2026-07-28,
    on {!Spindle_client} alone: a program that only calls tools installs and
    links no framework.

    {[
    let weather =
      Spindle_mcp_client.create client ~url:"https://weather.example.com/mcp"

    let* tools = Spindle_mcp_client.tools weather in
    let* forecast =
      Spindle_mcp_client.call weather "get_forecast" query_json
        { city = "Paris" } forecast_json
    in
    ...
    ]}

    Each call is one [POST], answered on its own, as 2026-07-28 has it: a value
    of this module holds the server's address, what this client says of itself,
    and the tools it last listed, and nothing of a session. Every request
    carries the headers and the [_meta] the revision asks for, and reads its
    answer as one JSON object or an event stream, whichever the server sent. *)

type t
(** A server to call. *)

type reply =
  | Accept of Wiretype.Value.t  (** the content, as the request's schema asks *)
  | Decline
  | Cancel  (** dismissed, with no choice made *)

type elicit = message:string -> schema:Wiretype.Value.t -> reply
(** How a question a server asks in the middle of a call is answered -- by a
    person, a form, a policy: its message, and the schema of what it asks for.
*)

val create :
  ?name:string ->
  ?version:string ->
  ?headers:(string * string) list ->
  ?elicit:elicit ->
  ?rounds:int ->
  ?oauth:Spindle_client.Oauth.oauth ->
  Spindle_client.t ->
  url:string ->
  t
(** [create client ~url]: the MCP endpoint at [url], called through [client].
    Where [name] and [version] are both given, every request names this client
    by them ([clientInfo]). [headers] go with every request: a credential, say.

    [elicit] answers a server's questions, and is how this client says it can
    ([elicitation] among its capabilities): without it, a server may not ask. A
    call a server asks of is retried with the answers, as a new request, at most
    [rounds] (3) times.

    [oauth] signs a person in where the server needs a token, as MCP's
    authorization has it: the token kept for [url] goes with every request; a
    [401] signs in at the authorization server its challenge's metadata names,
    and a [403] [insufficient_scope] steps up to the scope it names, keeping
    those granted, each retried once. Does no I/O. *)

(** {1 Answers} *)

type refusal = {
  status : Spindle_http.Status.t;
  code : int option;  (** the JSON-RPC error's, where one was sent *)
  message : string;  (** the server's words, for a log *)
}

type error =
  [ Spindle_client.error
  | `Refused of refusal
    (** the server answered no result: an HTTP refusal -- a [401], a [403], a
        [429] -- or a JSON-RPC error *)
  | `Unreadable of string
    (** an answer that is no MCP answer, or a result its description does not
        read; in words *)
  | `Unanswered of string
    (** a server that asked questions this client cannot answer -- it has no
        {!elicit}, or the rounds ran out *)
  | `Oauth of string  (** signing in failed, as {!Spindle_client.Oauth} says *)
  ]

val error_to_string : [< error | `Tool_failed of string ] -> string

(** {1 Calling} *)

type server = {
  versions : string list;  (** [supportedVersions] *)
  instructions : string option;  (** for a model, on using the server *)
  name : string option;  (** [serverInfo]'s, as it says of itself *)
  version : string option;
}

val discover : t -> (server, [> error ]) result
(** [server/discover]. *)

type tool = {
  name : string;
  title : string option;
  description : string option;
  input_schema : Wiretype.Value.t;
  output_schema : Wiretype.Value.t option;
}

val tools : t -> (tool list, [> error ]) result
(** [tools/list], every page, in the server's order. A tool whose [x-mcp-header]
    annotations break the rules of 2026-07-28 is left out, as the revision asks
    of a client, with a [warn] line naming it and why. The list is kept, for the
    headers each call mirrors. *)

type answer = {
  content : Wiretype.Value.t list;  (** for a model: text, images, links *)
  structured : Wiretype.Value.t option;  (** [structuredContent] *)
}

val call :
  t ->
  string ->
  'a Wiretype.t ->
  'a ->
  'r Wiretype.t ->
  ('r, [> error | `Tool_failed of string ]) result
(** [call t name arguments value result]: the tool [name], its arguments written
    by [arguments] and its [structuredContent] read by [result]. A result the
    tool marked [isError] is [`Tool_failed], its text. *)

val call_value :
  t ->
  string ->
  Wiretype.Value.t ->
  (answer, [> error | `Tool_failed of string ]) result
(** [call_value t name arguments]: as {!call}, for a program that passes a
    model's JSON through without knowing the tool. *)
