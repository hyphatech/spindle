(** Another site's page calling this one's routes, as the Fetch standard lets a
    server allow: one policy for the app ({!App.make}'s [cors]).

    {[
    Spindle.serve env
      ~cors:
        (Spindle.Cors.origins ~credentials:true [ "https://app.example.com" ])
      routes
    ]}

    {b The framework answers the preflight}: an [OPTIONS] with [Origin] and
    [Access-Control-Request-Method], on a path a covered route answers, is [204]
    with the methods the route table has there and the requested headers the
    policy allows -- even where the application declared an [OPTIONS] route at
    that path, which an [OPTIONS] without [Access-Control-Request-Method] still
    reaches. An origin the policy does not allow is answered without those
    headers, so the browser refuses and the server has said nothing.

    {b An answer to an allowed origin} carries [Access-Control-Allow-Origin]:
    the origin itself, or [*] under {!any}, which allows no credentials; and
    [Vary: Origin] is on every answer of a covered route, allowed or not, so a
    cache never hands one origin's answer to another.

    {b The forgery check.} A named origin is trusted by it on the routes the
    policy covers, since letting a site read an answer while refusing its writes
    is a policy nobody wants. {!any} trusts no origin with a credential the
    browser attached itself: a form another site's page posts is never
    preflighted, so trusting every origin would switch the check off, and under
    {!any} a request from another site passes only when it carries no [Cookie]
    and no [Authorization] in a scheme a browser keeps and sends without asking
    -- [Basic], [Digest], [Negotiate], [NTLM] -- nor one that is no credentials
    at all. A public API called with a token in [Authorization] under another
    scheme, [Bearer] say, which a page sets only through a preflight, is served;
    a forged write riding a session or a cached login is still [403]. *)

type t = Cors_repr.t

val origins :
  ?credentials:bool ->
  ?allow_headers:string list ->
  ?expose:string list ->
  ?max_age_s:int ->
  ?routes:(Route.info -> bool) ->
  string list ->
  t
(** [credentials] (false) lets the browser send cookies and read the answer;
    [allow_headers] are those a request may send ([authorization] and
    [content-type] unless given); [expose] those script may read (none);
    [max_age_s] how long a browser keeps a preflight's answer (600); [routes]
    which routes it covers (every one), for an app whose API is public and whose
    pages are not. *)

val any :
  ?allow_headers:string list ->
  ?expose:string list ->
  ?max_age_s:int ->
  ?routes:(Route.info -> bool) ->
  unit ->
  t
(** Any site may call the routes, and none with the user's cookies: there is no
    [credentials], since the Fetch standard allows none beside [*], so a policy
    that would let every site act as the signed-in person cannot be written. The
    rest is {!origins}'. *)
