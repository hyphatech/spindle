(** Another site's page calling this one's routes, as the Fetch standard lets a
    server allow: one policy for the app ({!App.make}'s [cors]), {!none} unless
    given, and a route's own in place of it where the route gives one
    ({!Route.maker}'s [cors]). A route the policy it has allows is covered.

    {[
    let app_site =
      Spindle.Cors.origins ~credentials:true [ "https://app.example.com" ]

    (* the whole app *)
    let () = Spindle.serve env ~cors:app_site routes

    (* or its API alone, the pages allowing no other site *)
    let api_get = Spindle.get ~cors:app_site
    ]}

    {b The framework answers the preflight}: an [OPTIONS] with [Origin] and
    [Access-Control-Request-Method], on a path where a covered route answers the
    method asked for, is [204] under that route's policy, with the methods the
    covered routes have there and the requested headers the policy allows --
    even where the application declared an [OPTIONS] route at that path, which
    an [OPTIONS] without [Access-Control-Request-Method] still reaches. An
    origin the policy does not allow is answered without those headers, so the
    browser refuses and the server has said nothing.

    {b An answer to an allowed origin} carries [Access-Control-Allow-Origin]:
    the origin itself, or [*] under {!any}, which allows no credentials; and
    [Vary: Origin] is on every answer of a covered route, allowed or not, so a
    cache never hands one origin's answer to another.

    {b The forgery check.} A named origin is trusted on the routes whose policy
    names it, since letting a site read an answer while refusing its writes is a
    policy nobody wants. {!any} trusts no origin with a credential the browser
    attached itself: a form another site's page posts is never preflighted, so
    trusting every origin would switch the check off, and under {!any} a request
    from another site passes only when it carries no [Cookie] and no
    [Authorization] in a scheme a browser keeps and sends without asking --
    [Basic], [Digest], [Negotiate], [NTLM] -- nor one that is no credentials at
    all. A public API called with a token in [Authorization] under another
    scheme, [Bearer] say, which a page sets only through a preflight, is served;
    a forged write riding a session or a cached login is still [403]. *)

type t = Cors_repr.t

val origins :
  ?credentials:bool ->
  ?allow_headers:string list ->
  ?expose:string list ->
  ?max_age_s:int ->
  string list ->
  t
(** [credentials] (false) lets the browser send cookies and read the answer;
    [allow_headers] are those a request may send ([authorization] and
    [content-type] unless given); [expose] those script may read (none); and
    [max_age_s] how long a browser keeps a preflight's answer (600). *)

val any :
  ?allow_headers:string list ->
  ?expose:string list ->
  ?max_age_s:int ->
  unit ->
  t
(** Any site may call the routes, and none with the user's cookies: there is no
    [credentials], since the Fetch standard allows none beside [*], so a policy
    that would let every site act as the signed-in person cannot be written. The
    rest is {!origins}'. *)

val none : t
(** Allows no other site: an app's policy unless it gives one, and a route's way
    to allow none under an app's that allows some. *)
