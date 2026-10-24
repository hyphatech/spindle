(** OAuth 2.0 bearer tokens, checked as a resource server checks them: a JWT
    access token (RFC 9068) sent in [Authorization] (RFC 6750 §2.1), signed with
    the issuer's keys and issued for this resource (RFC 8707), refused with the
    challenge RFC 6750 §3 names, and described by the metadata document RFC 9728
    has a client find the issuer from.

    {[
    let auth =
      Spindle.Bearer.make ~issuer:"https://id.example.com"
        ~resource:"https://api.example.com"

    let me =
      Spindle.get Path.(s "me") (Returns.json Wiretype.string)
        (let+ (c : Spindle.Bearer.claims) = Spindle.Bearer.claims auth in
         Ok c.subject)

    let notes =
      Spindle.get Path.(s "notes") (Returns.json notes_json)
        (let+ () = Spindle.Bearer.scope auth "notes:read" and+ ... in ...)

    let () =
      Eio_main.run @@ fun env ->
      Spindle_client.run env @@ fun client ->
      let keys = Spindle_client.Oauth.keys client ~issuer:"https://id.example.com" in
      Spindle.serve env
        ~resources:[ Spindle.Dep.resource (Spindle.Bearer.keys auth) keys ]
        (routes @ [ Spindle.Bearer.metadata auth routes ])
    ]}

    A token is read from [Authorization] and nowhere else: one in a query string
    is in every log it passes. Nothing of a token, or of its claims, is logged
    or traced; a refusal's detail says which check failed. *)

type t
(** A resource and the issuer whose tokens it accepts. *)

val make : issuer:string -> resource:string -> t
(** [issuer] is the authorization server's identifier, as its tokens' [iss]
    writes it, compared exactly: an https URL with no query or fragment (RFC
    8414 §2). [resource] is this server's: an https URL with no query or
    fragment (RFC 9728 §1.2), which a token's [aud] must name (RFC 8707 §2) and
    beneath which the metadata document is served (RFC 9728 §3.1). Raises
    [Invalid_argument] for an issuer or a resource that is no such URL: each is
    a constant written in source. *)

type claims = {
  subject : string;  (** [sub] *)
  client_id : string;  (** the client the token was issued to *)
  scopes : string list;  (** [scope], split at its spaces *)
  expires : Ptime.t;  (** [exp] *)
  issued : Ptime.t;  (** [iat] *)
  token_id : string;  (** [jti] *)
  payload : Wiretype.Value.t;
      (** every claim, for one of the application's own: read it with
          [Wiretype.of_value] *)
}
(** A token's claims, once every check RFC 9068 §4 names has passed. *)

type keys = kid:string option -> Spindle_http.Jwk.t list
(** The issuer's keys a token may be signed with: those of the [kid] it names,
    or every key where it names none. [Spindle_client.Oauth.keys] fetches them
    from the issuer's metadata; a test gives its own. *)

val keys : t -> keys Dep.t
(** The issuer's keys, a resource the program supplies when it starts
    ({!Dep.val-resource}). *)

val claims : t -> claims Dep.t
(** The checked token's claims: a credential named [bearer]. A request with no
    bearer token is refused [token_required], a [401] that names no error (RFC
    6750 §3); a malformed [Authorization] [invalid_request], a [400]; and a
    token that fails any check [invalid_token], a [401] -- its signature under
    {!val-keys}, by RS256, ES256 or EdDSA; its [typ], [at+jwt] or
    [application/at+jwt]; its [iss], the issuer; its [aud], naming the resource;
    [exp] after {!Spindle.now} and [nbf], if any, not after it; and [sub],
    [client_id], [iat] and [jti] present (RFC 9068 §2.2, §4). Each challenge
    names the metadata document ([resource_metadata], RFC 9728 §5.1), so the
    codes are the same for every [t] of one resource. *)

val scope : t -> string -> unit Dep.t
(** That the token grants [scope]: {!val-claims}, then [insufficient_scope], a
    [403] whose challenge names the scope (RFC 6750 §3.1). A credential naming
    the scope, so the API's document and {!metadata} list it. Raises
    [Invalid_argument] for a scope that is no [scope-token] (RFC 6749 §3.3): a
    constant written in source. *)

val insufficient_scope : Refusal.Code.t
(** [403 insufficient_scope]: a token that does not grant a scope this needs
    (RFC 6750 §3.1). {!scope} declares it; a route that knows the scope it needs
    only as it runs declares it itself, and answers {!lacking}. *)

val lacking : t -> string -> Refusal.t
(** The refusal {!scope} answers for a token that does not grant [scope], its
    challenge naming the scope and the metadata document. *)

val metadata : t -> Route.t list -> Route.t
(** The protected resource's metadata (RFC 9728 §2), at
    [/.well-known/oauth-protected-resource] followed by the resource's path
    (§3.1): the resource, its issuer as [authorization_servers], every scope
    [routes] read through {!scope} as [scopes_supported], and [header] as the
    one bearer method. *)
