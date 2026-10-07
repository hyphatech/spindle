(** Another site's page calling this one's routes, as the Fetch standard lets a
    server allow: one policy for the app ({!App.make}'s [cors]).

    {[
    Spindle.serve env
      ~cors:
        (Spindle.Cors.make ~credentials:true
           (Spindle.Cors.Origins [ "https://app.example.com" ]))
      routes
    ]}

    {b The framework answers the preflight}: an [OPTIONS] with [Origin] and
    [Access-Control-Request-Method], on a path a covered route answers, is [204]
    with the methods the route table has there and the requested headers the
    policy allows -- even where the application declared an [OPTIONS] route at
    that path, which an [OPTIONS] without [Access-Control-Request-Method] still
    reaches. An origin the policy does not allow is answered without those
    headers, so the browser refuses and the server has said nothing.

    {b An answer to an allowed origin} carries [Access-Control-Allow-Origin],
    the origin itself, and [Vary: Origin] is on every answer of a covered route,
    allowed or not, so a cache never hands one origin's answer to another.

    {b The forgery check.} A named origin is trusted by it on the routes the
    policy covers, since letting a site read an answer while refusing its writes
    is a policy nobody wants. [Any] trusts no origin with a cookie: a form
    another site's page posts is never preflighted, so trusting every origin
    would switch the check off, and under [Any] a request from another site
    passes only when it carries no [Cookie] -- the credential a browser attaches
    without asking. A public API called with a token in [Authorization], which a
    page sets only through a preflight, is served; a forged write riding a
    session is still [403]. *)

type origins = Cors_repr.origins =
  | Origins of string list
      (** each as a browser writes it: [https://a.example] *)
  | Any

type t = Cors_repr.t

val make :
  ?credentials:bool ->
  ?headers:string list ->
  ?expose:string list ->
  ?max_age_s:int ->
  ?routes:(Route.info -> bool) ->
  origins ->
  t
(** [credentials] (false) lets the browser send cookies and read the answer;
    [headers] are those a request may send ([authorization] and [content-type]
    unless given); [expose] those script may read (none); [max_age_s] how long a
    browser keeps a preflight's answer (600); [routes] which routes it covers
    (every one), for an app whose API is public and whose pages are not. Raises
    [Invalid_argument] for [Any] beside [~credentials:true], which the Fetch
    standard does not allow, since a policy is a constant written in source. *)
