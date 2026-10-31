(** Calling another server's tools, and reading and watching its resources, over
    the Model Context Protocol, 2026-07-28, on {!Spindle_client} alone: a
    program that only calls another server installs and links no framework.

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

type progress = {
  progress : float;  (** how far the call has come *)
  total : float option;
  message : string option;
}
(** A report a server sent while a call ran. *)

type answer = {
  content : Wiretype.Value.t list;  (** for a model: text, images, links *)
  structured : Wiretype.Value.t option;  (** [structuredContent] *)
}

val call :
  ?progress:(progress -> unit) ->
  t ->
  string ->
  'a Wiretype.t ->
  'a ->
  'r Wiretype.t ->
  ('r, [> error | `Tool_failed of string ]) result
(** [call t name arguments value result]: the tool [name], its arguments written
    by [arguments] and its [structuredContent] read by [result]. A result the
    tool marked [isError] is [`Tool_failed], its text. [progress] is told each
    report the server sends while the tool runs, as it arrives, and asks the
    server for them ([progressToken]); without it, none is asked for. *)

val call_value :
  ?progress:(progress -> unit) ->
  t ->
  string ->
  Wiretype.Value.t ->
  (answer, [> error | `Tool_failed of string ]) result
(** [call_value t name arguments]: as {!call}, for a program that passes a
    model's JSON through without knowing the tool. *)

(** {1 Resources} *)

type resource = {
  uri : string;
  name : string;
  title : string option;  (** for a person *)
  description : string option;  (** for a model *)
  mime : string option;
}

type template = {
  uri_template : string;  (** RFC 6570 *)
  name : string;
  title : string option;
  description : string option;
  mime : string option;
}

type data = Text of string | Blob of string  (** bytes, decoded from base64 *)

type content = { uri : string; mime : string option; data : data }
(** One of what a read answers: a resource may answer several. *)

val resources : t -> (resource list, [> error ]) result
(** [resources/list], every page, in the server's order. *)

val templates : t -> (template list, [> error ]) result
(** [resources/templates/list], every page, in the server's order. *)

val read : t -> string -> (content list, [> error ]) result
(** [resources/read] of a URI, mirrored in [Mcp-Name]. A resource the server has
    not is [`Refused] with the code [-32602]. *)

(** {1 Watching} *)

(** What a listen hands its caller. *)
type notification =
  | Acknowledged of string list
      (** the URIs the server watches for this listen, always first: one it left
          out it will never tell of *)
  | Updated of string  (** a URI that changed: read it again *)

(** How a listen ended, once acknowledged. *)
type ended =
  | Stopped  (** the function answered [`Stop] *)
  | Completed
      (** the server ended it, with the graceful result: it has nothing more to
          tell this listen *)
  | Dropped of string
      (** it ended without that result -- the connection lost, the server
          dropping a listen that fell behind, no word within [read_timeout] --
          in words: changes may have been missed, and the caller listens again
          and reads from where it was *)

val listen :
  ?read_timeout:Mtime.Span.t ->
  t ->
  string list ->
  (notification -> [ `Continue | `Stop ]) ->
  (ended, [> error ]) result
(** [listen t uris f]: [subscriptions/listen] for [uris], each notification
    handed to [f] as it arrives, until the listen ends or [f] answers [`Stop].
    It runs in the caller's fiber and keeps nothing of the stream; a program
    reads beside it, in a fiber of its own or from [f].

    A change made after [Acknowledged] is told, so a caller that reads from its
    own place once acknowledged, and again on each [Updated], misses nothing. An
    [error] is a listen refused or never acknowledged; once acknowledged, a
    stream cut off is [Dropped], since the caller's answer to either is to
    listen again. It never listens again by itself: whether to, and how long to
    wait first, are the caller's.

    {[
    let rec watch () =
      match
        Spindle_mcp_client.listen mcp [ uri ] (fun _ ->
            catch_up ();
            `Continue)
      with
      | Ok (Dropped _) ->
          Eio.Time.Mono.sleep_span clock Mtime.Span.(1 * s);
          watch ()
      | Ok (Completed | Stopped) -> Ok ()
      | Error _ as e -> e
    ]}

    [read_timeout] (60 s) bounds each wait for more of the stream, never the
    whole: four of a Spindle server's keep-alives. A notification of another
    listen, or of a kind not asked for, is dropped with a [warn] line, as a
    server never sends one. *)
