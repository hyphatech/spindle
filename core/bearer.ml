module Auth = Spindle_http.Auth
module Jws = Spindle_http.Jws

type keys = kid:string option -> Spindle_http.Jwk.t list

type claims = {
  subject : string;
  client_id : string;
  scopes : string list;
  expires : Ptime.t;
  issued : Ptime.t;
  token_id : string;
  payload : Wiretype.Value.t;
}

type t = {
  issuer : string;
  resource : string;
  metadata_url : string;
  metadata_path : Path.path;
  keys : keys Dep.t;
  claims : claims Dep.t;
}

(* RFC 6750 §3: the challenge's parameters, each a quoted string. *)
let challenge ?error ?scope metadata_url =
  let param name v = Printf.sprintf "%s=%S" name v in
  "Bearer "
  ^ String.concat ", "
      (List.filter_map Fun.id
         [
           Option.map (param "error") error;
           Option.map (param "scope") scope;
           Some (param "resource_metadata" metadata_url);
         ])

let token_required url =
  Refusal.Code.make "token_required" ~status:`Unauthorized
    ~challenge:(challenge url)
    ~doc:
      "No bearer token was sent. The challenge names the resource's metadata, \
       which names where to get one."

let invalid_request url =
  Refusal.Code.make "invalid_request" ~status:`Bad_request
    ~challenge:(challenge ~error:"invalid_request" url)
    ~doc:"The Authorization header is malformed."

let invalid_token url =
  Refusal.Code.make "invalid_token" ~status:`Unauthorized
    ~challenge:(challenge ~error:"invalid_token" url)
    ~doc:
      "The bearer token is not one this resource accepts: not signed by its \
       issuer, not for this resource, expired, or not an access token."

(* Its challenge names the scope a route needs, so each refusal writes its
   own. *)
let insufficient_scope =
  Refusal.Code.make "insufficient_scope" ~status:`Forbidden
    ~doc:"The bearer token does not grant a scope this needs."

let ( let* ) = Result.bind

let numeric_date name f =
  Option.to_result (Ptime.of_float_s f)
    ~none:(Printf.sprintf "%s is no instant" name)

type read = {
  iss : string;
  aud : Wiretype.Value.t;
  sub : string;
  client_id : string;
  iat : float;
  exp : float;
  nbf : float option;
  jti : string;
  scope : string option;
}

(* RFC 9068 §2.2: the claims every access token carries. *)
let read_json =
  Wiretype.Object.(
    map (fun iss aud sub client_id iat exp nbf jti scope ->
        { iss; aud; sub; client_id; iat; exp; nbf; jti; scope })
    |> mem "iss" Wiretype.string
    |> mem "aud" Wiretype.Value.json
    |> mem "sub" Wiretype.string
    |> mem "client_id" Wiretype.string
    |> mem "iat" Wiretype.number |> mem "exp" Wiretype.number
    |> opt_mem "nbf" Wiretype.number
    |> mem "jti" Wiretype.string
    |> opt_mem "scope" Wiretype.string
    |> finish)

let audience = function
  | Wiretype.Value.String s -> Ok [ s ]
  | Array values ->
      List.fold_right
        (fun v acc ->
          match (v, acc) with
          | Wiretype.Value.String s, Ok l -> Ok (s :: l)
          | _, Ok _ -> Error "aud holds a value that is no string"
          | _, (Error _ as e) -> e)
        values (Ok [])
  | _ -> Error "aud is no string or array"

(* RFC 9068 §4, in its order: the header's type, the signature, then the
   claims. Each [Error] says which check failed, and nothing of the token. *)
let check ~issuer ~resource ~now ~(keys : keys) token =
  let* jws = Result.map_error Jws.error_to_string (Jws.of_string token) in
  let* () =
    match Option.map String.lowercase_ascii (Jws.typ jws) with
    | Some ("at+jwt" | "application/at+jwt") -> Ok ()
    | Some _ | None -> Error "typ is not at+jwt"
  in
  let* payload =
    Result.map_error Jws.error_to_string
      (Jws.verify jws ~keys:(keys ~kid:(Jws.kid jws)))
  in
  let* r =
    Result.map_error
      (fun _ -> "the claims are no JSON object of those RFC 9068 requires")
      (Wiretype.decode read_json payload)
  in
  let* () =
    if String.equal r.iss issuer then Ok () else Error "iss is another issuer"
  in
  let* aud = audience r.aud in
  let* () =
    if List.exists (String.equal resource) aud then Ok ()
    else Error "aud does not name this resource"
  in
  let* expires = numeric_date "exp" r.exp in
  let* issued = numeric_date "iat" r.iat in
  let* () =
    if Ptime.is_earlier now ~than:expires then Ok () else Error "expired"
  in
  let* () =
    match r.nbf with
    | None -> Ok ()
    | Some f ->
        let* nbf = numeric_date "nbf" f in
        if Ptime.is_earlier now ~than:nbf then Error "not yet valid" else Ok ()
  in
  let* payload =
    Result.map_error
      (fun _ -> "the claims are no JSON")
      (Wiretype.decode Wiretype.Value.json payload)
  in
  Ok
    {
      subject = r.sub;
      client_id = r.client_id;
      scopes =
        (match r.scope with
        | None -> []
        | Some s ->
            List.filter
              (fun x -> not (String.equal x ""))
              (String.split_on_char ' ' s));
      expires;
      issued;
      token_id = r.jti;
      payload;
    }

let authorization = Header.optional "authorization" Wiretype.string
let now = Dep.of_request ~needs:[] (fun r -> Ok (Request.now r))

let claims_of ~issuer ~resource ~metadata_url ~keys =
  let token_required = token_required metadata_url
  and invalid_request = invalid_request metadata_url
  and invalid_token = invalid_token metadata_url in
  let read ((header, now), keys) =
    match header with
    | None -> Error (Refusal.make token_required "A bearer token is needed.")
    | Some value -> (
        let malformed =
          Refusal.make invalid_request "The Authorization header is malformed."
        in
        match Auth.credentials value with
        | Error _ -> Error malformed
        | Ok { scheme = "bearer"; value = Token68 token } ->
            Result.map_error
              (fun why ->
                Refusal.make ~detail:why invalid_token
                  "The bearer token is not valid here.")
              (check ~issuer ~resource ~now ~keys token)
        | Ok { scheme = "bearer"; value = Params _ } -> Error malformed
        (* RFC 6750 §3: another scheme is no bearer token, so no error. *)
        | Ok _ ->
            Error (Refusal.make token_required "A bearer token is needed."))
  in
  Dep.credential ~scheme:"bearer"
    ~doc:"An OAuth 2.0 access token: a JWT (RFC 9068), sent as a bearer token."
    (Dep.join
       ~refuses:[ token_required; invalid_request; invalid_token ]
       (Dep.map read (Dep.both (Dep.both authorization now) keys)))

(* An https URL with no query or fragment (RFC 8414 §2, RFC 9728 §1.2). *)
let https_url name s =
  let u = Uri.of_string s in
  match (Uri.scheme u, Uri.host u, Uri.verbatim_query u, Uri.fragment u) with
  | Some "https", Some host, None, None when not (String.equal host "") -> u
  | _ ->
      invalid_arg
        (Printf.sprintf
           "Spindle.Bearer.make: %s %S is no https URL without a query or a \
            fragment"
           name s)

(* RFC 9728 §3.1: the well-known name goes between the host and the
   resource's own path. *)
let metadata_location resource =
  let segments =
    List.filter
      (fun s -> not (String.equal s ""))
      (String.split_on_char '/' (Uri.path resource))
  in
  let path =
    List.fold_left
      (fun p seg -> Path.(p / s seg))
      Path.(s ".well-known" / s "oauth-protected-resource")
      segments
  in
  let url =
    Uri.to_string
      (Uri.with_path resource
         ("/.well-known/oauth-protected-resource"
         ^ String.concat "" (List.map (fun s -> "/" ^ s) segments)))
  in
  (path, url)

let make ~issuer ~resource =
  let (_ : Uri.t) = https_url "the issuer" issuer in
  let metadata_path, metadata_url =
    metadata_location (https_url "the resource" resource)
  in
  let keys = Dep.of_resource ("the keys of " ^ issuer) in
  (* A token's subject is whoever is calling. *)
  let claims =
    Dep_repr.mark Caller (claims_of ~issuer ~resource ~metadata_url ~keys)
  in
  { issuer; resource; metadata_url; metadata_path; keys; claims }

let keys t = t.keys
let claims t = t.claims

(* RFC 6749 §3.3: scope-token = 1*NQCHAR. *)
let is_scope_token s =
  (not (String.equal s ""))
  && String.for_all
       (fun c ->
         match c with
         | '\x21' | '\x23' .. '\x5b' | '\x5d' .. '\x7e' -> true
         | _ -> false)
       s

let lacking t s =
  Refusal.make
    ~headers:
      [
        ( "www-authenticate",
          challenge ~error:"insufficient_scope" ~scope:s t.metadata_url );
      ]
    insufficient_scope "The bearer token does not grant what this needs."

let scope t s =
  if not (is_scope_token s) then
    invalid_arg
      (Printf.sprintf
         "Spindle.Bearer.scope: %S is no scope-token (RFC 6749 §3.3)" s);
  let lacking = lacking t s in
  Dep.credential ~scheme:"bearer" ~scopes:[ s ]
    (Dep.join ~refuses:[ insufficient_scope ]
       (Dep.map
          (fun (c : claims) ->
            if List.exists (String.equal s) c.scopes then Ok ()
            else Error lacking)
          t.claims))

type document = {
  resource : string;
  authorization_servers : string list;
  scopes_supported : string list;
  bearer_methods_supported : string list;
}

let document_json =
  let strings = Wiretype.list Wiretype.string in
  Wiretype.Object.(
    map
      (fun
        resource
        authorization_servers
        scopes_supported
        bearer_methods_supported
      ->
        {
          resource;
          authorization_servers;
          scopes_supported;
          bearer_methods_supported;
        })
    |> mem "resource" Wiretype.string ~enc:(fun d -> d.resource)
    |> mem "authorization_servers" strings ~enc:(fun d ->
        d.authorization_servers)
    |> mem "scopes_supported" strings ~absent:[]
         ~omit:(function [] -> true | _ :: _ -> false)
         ~enc:(fun d -> d.scopes_supported)
    |> mem "bearer_methods_supported" strings ~enc:(fun d ->
        d.bearer_methods_supported)
    |> finish)

let metadata (t : t) routes =
  let scopes =
    List.fold_left
      (fun acc s ->
        if List.exists (String.equal s) acc then acc else acc @ [ s ])
      []
      (List.concat_map
         (fun r ->
           List.concat_map
             (fun (c : Dep.credential) ->
               if String.equal c.scheme "bearer" then c.scopes else [])
             (Route.info r).credentials)
         routes)
  in
  let document =
    {
      resource = t.resource;
      authorization_servers = [ t.issuer ];
      scopes_supported = scopes;
      (* RFC 6750 §2.1 alone: a token anywhere else is in every log. *)
      bearer_methods_supported = [ "header" ];
    }
  in
  (* RFC 9728 §3: read by a client before it holds a token. *)
  Route_repr.public
    (Route_repr.get t.metadata_path
       (Returns.json document_json)
       (Dep.return (Ok document)))
