(** A request answered with "no": a code, a sentence and a detail.

    The client is sent the code and the sentence as
    [{"error": code, "message": sentence}]. The code is what a client branches
    on and the sentence is what a person reads, so it is a sentence -- a
    capital, a stop -- written for whoever is using the application, never an
    upstream service's wording or a parser's. The detail is what whoever runs
    the server needs, and it goes to the log and nowhere else. *)

(** A code: its name, its status, and what it means. A code is declared once and
    a refusal is made from it, so every code a route may answer with is a value
    that can be listed. *)
module Code : sig
  type t

  val make :
    ?challenge:string ->
    string ->
    status:Spindle_http.Status.t ->
    doc:string ->
    t
  (** [make "conflict" ~status:`Conflict ~doc:"Two writers raced."]. [doc] says
      what the code means, for whoever reads the routes' documentation.

      [challenge] is what a refusal made from the code says in
      [WWW-Authenticate]: RFC 9110 §15.5.2 has every [401] carry one, naming how
      to authenticate -- [Bearer realm="api"], or for a credential with no
      registered scheme, such as a session cookie, a scheme of the application's
      own. {!App.make} refuses a [401] declared without one. *)

  val name : t -> string
  val status : t -> Spindle_http.Status.t
  val challenge : t -> string option
  val doc : t -> string

  val equal : t -> t -> bool
  (** By name: a code is what a client branches on. *)

  (** {1 The framework's own}

      Any route may refuse with these without declaring them. *)

  val not_found : t
  val method_not_allowed : t
  val unreadable : t
  val invalid : t
  val too_large : t
  val busy : t
  val cross_origin : t
  val not_implemented : t
  val upgrade_required : t
  val internal : t

  val framework : t list
  (** All of the above. *)

  val unsupported_media_type : t
  (** [415]: a body sent as something the route does not read. It is not among
      {!framework}: a dependency that reads a body of one type declares it --
      {!Spindle.json}, {!Spindle.Form}'s, {!Spindle.multipart}, and
      {!Spindle.body_stream} and {!Dep.of_body} given a [content_type] -- so a
      route's document names it where the route answers it, and nowhere else. *)

  val rate_limited : t
  (** [429]: asked more often than the route allows. It is not among
      {!framework}: {!Rate.limit} declares it, so a route's document names the
      [429] where it may be answered and nowhere else. *)
end

type problem = {
  at : string;  (** where: [path.order_id], [query.page], [body.name] *)
  code : string;  (** what a client branches on, for that input *)
  message : string;  (** a sentence about that one input *)
}
(** One thing wrong with a request's input. *)

type t = private {
  code : Code.t;
  message : string;
  detail : string option;
  raised : (exn * Printexc.raw_backtrace) option;
      (** what a handler raised, and where, for the log *)
  headers : (string * string) list;
  problems : problem list;
}

val make :
  ?detail:string ->
  ?headers:(string * string) list ->
  ?problems:problem list ->
  Code.t ->
  string ->
  t
(** [make code message]. [problems] go to the client as
    [{"error": code, "message": sentence, "problems": [{"at", "code",
     "message"}]}], and are left out when there are none. *)

val status : t -> Spindle_http.Status.t
(** The code's. *)

(** {1 The framework's own}

    What the framework answers by itself, each a sentence. An application that
    wants other words makes its own from the same code. *)

val not_found : t
val method_not_allowed : allow:Spindle_http.Meth.t list -> t

val unreadable : detail:string -> t
(** A body that could not be read as sent -- cut short, malformed in its
    framing, or too slow to arrive: [400 unreadable]. A body that arrived whole
    and is not what the route reads is {!invalid}'s. *)

val invalid : problem list -> t
(** Inputs that are not what the route reads -- a path parameter that does not
    parse, a query parameter that is missing: [400 invalid], each problem saying
    where. Two of these in the same stage of the dependencies are one refusal
    with all their problems ({!Dep.both}). *)

val too_large : t

val rate_limited : retry_after:int -> unit -> t
(** [429 rate_limited] with [Retry-After], at least a second: what {!Rate.limit}
    refuses with. *)

val busy : ?retry_after:int -> ?detail:string -> unit -> t
(** Something the request needed did not come free in time -- a connection, room
    for its body: [503 busy], with [Retry-After] ([retry_after] seconds, 1).
    Refusing at once is what keeps an overloaded server answering; the client is
    the one that can wait. *)

val unsupported_media_type : t
(** A body sent as something the route does not read: [415]. *)

val cross_origin : t
(** An unsafe request a browser sent from another site: [403] (see {!App.make}).
*)

val not_implemented : t
(** A method the server does not implement -- one no route declares and the
    framework does not know: [501] (RFC 9110 §9.1). *)

val internal : detail:string -> t
(** Our fault: [500 internal], with the detail for the log. *)

val raised : exn -> Printexc.raw_backtrace -> t
(** A handler that raised: {!internal}, keeping the exception and its backtrace
    so the log can say where. *)
