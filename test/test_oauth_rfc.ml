(* OAuth as Spindle checks it, a row a requirement, named by its RFC and
   section: JOSE's signatures and keys (RFC 7515, 7517, 7518, 8037), each
   published example verified as it is printed; then a resource server's
   bearer tokens (RFC 6750, 8707, 9068) and its metadata (RFC 9728). *)

module Jwk = Spindle_http.Jwk
module Jws = Spindle_http.Jws
module Bearer = Spindle.Bearer
open Spindle.Syntax

let check_bool = Alcotest.(check bool)
let check_string = Alcotest.(check string)
let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* ------------------------------------------------------------------ *)
(* The RFCs' examples *)

(* RFC 7515 A.2: RS256, over A.1's payload, with A.2's key. *)
let rs256_jwk =
  {|{"kty":"RSA","n":"ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ","e":"AQAB"}|}

let rs256_jws =
  "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw"

(* RFC 7515 A.3: ES256, over the same payload. *)
let es256_jwk =
  {|{"kty":"EC","crv":"P-256","x":"f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU","y":"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"}|}

let es256_jws =
  "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q"

let a1_payload =
  "{\"iss\":\"joe\",\r\n\
  \ \"exp\":1300819380,\r\n\
  \ \"http://example.com/is_root\":true}"

(* RFC 8037 A.2 and A.4: EdDSA on Ed25519. *)
let ed25519_jwk =
  {|{"kty":"OKP","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}|}

let ed25519_jws =
  "eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc.hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg"

let key s =
  match Jwk.of_string s with
  | Ok k -> k
  | Error e -> Alcotest.failf "a key that should read: %s" e

let verified ?(keys = []) s =
  match Jws.of_string s with
  | Error e -> Error e
  | Ok jws -> Jws.verify jws ~keys

let check_verified name ~keys s payload =
  match verified ~keys s with
  | Ok p -> check_string name payload p
  | Error e -> Alcotest.failf "%s: %s" name (Jws.error_to_string e)

let check_refused name ~keys s =
  match verified ~keys s with
  | Ok _ -> Alcotest.failf "%s: verified" name
  | Error _ -> ()

let all_three () = [ key rs256_jwk; key es256_jwk; key ed25519_jwk ]

let test_rs256_example () =
  check_verified "A.2" ~keys:[ key rs256_jwk ] rs256_jws a1_payload

let test_es256_example () =
  check_verified "A.3" ~keys:[ key es256_jwk ] es256_jws a1_payload

let test_eddsa_example () =
  check_verified "A.4"
    ~keys:[ key ed25519_jwk ]
    ed25519_jws "Example of Ed25519 signing"

(* Each example among all three keys finds its own: a key of another kind is
   never tried. *)
let test_a_key_of_another_kind_is_not_tried () =
  check_verified "RS256" ~keys:(all_three ()) rs256_jws a1_payload;
  check_verified "ES256" ~keys:(all_three ()) es256_jws a1_payload;
  check_verified "EdDSA" ~keys:(all_three ()) ed25519_jws
    "Example of Ed25519 signing";
  match verified ~keys:[ key es256_jwk; key ed25519_jwk ] rs256_jws with
  | Error No_key -> ()
  | Ok _ -> Alcotest.fail "an RSA signature checked by another kind"
  | Error e -> Alcotest.failf "not No_key: %s" (Jws.error_to_string e)

(* ------------------------------------------------------------------ *)
(* Signing, for the rows the examples do not reach *)

let ed_priv, ed_pub =
  Mirage_crypto_rng_unix.use_default ();
  Mirage_crypto_ec.Ed25519.generate ()

let ed_jwk ?kid ?alg ?use () =
  let member name = function
    | None -> ""
    | Some v -> Printf.sprintf {|,"%s":"%s"|} name v
  in
  Printf.sprintf {|{"kty":"OKP","crv":"Ed25519","x":"%s"%s%s%s}|}
    (b64 (Mirage_crypto_ec.Ed25519.pub_to_octets ed_pub))
    (member "kid" kid) (member "alg" alg) (member "use" use)

(* A compact JWS of this header, as written, over this payload. *)
let ed_signed header payload =
  let input = b64 header ^ "." ^ b64 payload in
  input ^ "." ^ b64 (Mirage_crypto_ec.Ed25519.sign ~key:ed_priv input)

let check_error name expected s ~keys =
  match verified ~keys s with
  | Ok _ -> Alcotest.failf "%s: verified" name
  | Error e ->
      check_string name (Jws.error_to_string expected) (Jws.error_to_string e)

(* RFC 7515 §5.2: a JWS is valid only where its signature is; a JWS whose
   signature is not checked here is not one this reader accepts. *)
let test_alg_none_is_refused () =
  let unsigned = b64 {|{"alg":"none"}|} ^ "." ^ b64 "payload" ^ "." in
  check_refused "none, its signature empty" ~keys:[ key (ed_jwk ()) ] unsigned;
  check_error "none, signed" (Unsupported_algorithm "none")
    (ed_signed {|{"alg":"none"}|} "payload")
    ~keys:[ key (ed_jwk ()) ]

let test_hmac_is_refused () =
  check_error "HS256" (Unsupported_algorithm "HS256")
    (ed_signed {|{"alg":"HS256"}|} "payload")
    ~keys:[ key (ed_jwk ()) ]

(* RFC 7515 §4.1.11: an extension named critical that the reader does not
   understand makes the JWS invalid. *)
let test_crit_is_refused () =
  check_error "crit" (Critical [ "exp" ])
    (ed_signed {|{"alg":"EdDSA","crit":["exp"],"exp":1}|} "payload")
    ~keys:[ key (ed_jwk ()) ]

(* RFC 7515 §4: a header naming a parameter twice is refused. *)
let test_a_header_parameter_twice_is_refused () =
  check_refused "alg twice"
    ~keys:[ key (ed_jwk ()) ]
    (ed_signed {|{"alg":"EdDSA","alg":"none"}|} "payload")

(* RFC 7515 §4.1.1: "alg" is required. *)
let test_a_header_without_alg_is_refused () =
  check_refused "no alg"
    ~keys:[ key (ed_jwk ()) ]
    (ed_signed {|{"kid":"a"}|} "payload")

(* RFC 7515 §7.1: three parts, each base64url without padding. *)
let test_the_compact_form_is_read_strictly () =
  let good = ed_signed {|{"alg":"EdDSA"}|} "payload" in
  let keys = [ key (ed_jwk ()) ] in
  check_verified "the token itself" ~keys good "payload";
  List.iter
    (fun (name, s) -> check_refused name ~keys s)
    [
      ("two parts", String.concat "." [ "eyJhbGciOiJFZERTQSJ9"; "cGF5bG9hZA" ]);
      ("four parts", good ^ ".x");
      ("padding", good ^ "==");
      ( "a character no base64url has",
        String.map (function '-' -> '+' | c -> c) good ^ "+" );
      ("whitespace", " " ^ good);
      ("an empty header", "." ^ b64 "payload" ^ ".AAAA");
      ("a header that is no JSON", b64 "alg" ^ "." ^ b64 "p" ^ ".AAAA");
      ("a header that is no object", b64 {|["EdDSA"]|} ^ "." ^ b64 "p" ^ ".AAAA");
    ]

(* RFC 7515 §5.2 step 8: the signature is checked over the signing input
   as it was sent, so any character of the token changed is a token that is
   refused -- the bits base64url leaves unused at a part's end included,
   which a reader that ignored them would accept changed. *)
let test_any_character_changed_is_refused =
  let alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."
  in
  let tokens = [| rs256_jws; es256_jws; ed25519_jws |] in
  QCheck_alcotest.to_alcotest
    (QCheck.Test.make ~count:2000 ~name:"7515 §5.2: any character changed"
       QCheck.(triple (int_bound 2) (int_bound 1000) (int_bound 64))
       (fun (which, at, by) ->
         let token = tokens.(which) in
         let at = at mod String.length token in
         let c = alphabet.[by] in
         QCheck.assume (not (Char.equal token.[at] c));
         let changed = String.mapi (fun i x -> if i = at then c else x) token in
         match verified ~keys:(all_three ()) changed with
         | Ok _ -> false
         | Error _ -> true))

(* RFC 7515 §4.1.4: a "kid" picks the key; one naming no key of the set
   finds none, rather than any. *)
let test_a_kid_picks_its_key () =
  let token = ed_signed {|{"alg":"EdDSA","kid":"one"}|} "payload" in
  check_verified "its kid" ~keys:[ key (ed_jwk ~kid:"one" ()) ] token "payload";
  check_error "another kid" No_key token ~keys:[ key (ed_jwk ~kid:"two" ()) ];
  check_verified "a key with no kid is not the one named"
    ~keys:[ key (ed_jwk ~kid:"one" ()) ]
    (ed_signed {|{"alg":"EdDSA"}|} "payload")
    "payload"

(* RFC 7517 §4.4: a key's "alg" is the one algorithm it is for. *)
let test_a_keys_alg_binds_it () =
  check_verified "EdDSA's key"
    ~keys:[ key (ed_jwk ~alg:"EdDSA" ()) ]
    (ed_signed {|{"alg":"EdDSA"}|} "payload")
    "payload";
  match Jwk.of_string (ed_jwk ~alg:"ES256" ()) with
  | Error _ -> ()
  | Ok k ->
      check_error "a key for another alg" No_key ~keys:[ k ]
        (ed_signed {|{"alg":"EdDSA"}|} "payload")

(* ------------------------------------------------------------------ *)
(* Keys *)

let refused_key name s =
  match Jwk.of_string s with
  | Ok _ -> Alcotest.failf "%s: read as a key" name
  | Error _ -> ()

(* RFC 7518 §3.3: RS256's key is 2048 bits or more. *)
let test_a_short_rsa_key_is_refused () =
  let n1024 = b64 ("\xc3" ^ String.make 127 '\x11') in
  refused_key "1024 bits"
    (Printf.sprintf {|{"kty":"RSA","n":"%s","e":"AQAB"}|} n1024);
  check_bool "2048 bits" true
    (match Jwk.of_string rs256_jwk with Ok _ -> true | Error _ -> false)

(* RFC 7518 §6.2.1.2-3: x and y are the curve's size, 32 octets for P-256,
   and the point is on the curve. *)
let test_a_p256_key_is_its_size_and_on_the_curve () =
  refused_key "x short"
    {|{"kty":"EC","crv":"P-256","x":"f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVE","y":"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"}|};
  refused_key "off the curve"
    {|{"kty":"EC","crv":"P-256","x":"f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU","y":"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a1"}|};
  refused_key "P-384" {|{"kty":"EC","crv":"P-384","x":"AAAA","y":"AAAA"}|}

(* RFC 7517 §4.2: a key whose "use" is not "sig" signs nothing. *)
let test_a_key_for_encryption_is_refused () =
  refused_key "use enc" (ed_jwk ~use:"enc" ());
  check_bool "use sig" true
    (match Jwk.of_string (ed_jwk ~use:"sig" ()) with
    | Ok _ -> true
    | Error _ -> false)

(* RFC 7517 §5: a set's keys this reader does not understand are left out,
   and the rest kept, in order. *)
let test_a_set_keeps_the_keys_it_reads () =
  let set =
    Printf.sprintf
      {|{"keys":[%s,{"kty":"oct","k":"c2VjcmV0"},%s,{"kty":"EC"},%s]}|}
      rs256_jwk (ed_jwk ~use:"enc" ()) ed25519_jwk
  in
  match Jwk.set_of_string set with
  | Error e -> Alcotest.failf "a set: %s" e
  | Ok keys ->
      check_bool "RSA, then Ed25519" true
        (match List.map Jwk.kind keys with
        | [ Rsa; Ed25519 ] -> true
        | _ -> false);
      check_bool "no keys member" true
        (match Jwk.set_of_string {|{"key":[]}|} with
        | Error _ -> true
        | Ok _ -> false)

(* ------------------------------------------------------------------ *)
(* A resource server's bearer tokens *)

let issuer = "https://id.example.com"
let resource = "https://api.example.com/mcp"

let metadata_url =
  "https://api.example.com/.well-known/oauth-protected-resource/mcp"

let auth = Bearer.make ~issuer ~resource

(* 2026-10-23T12:00:00Z, and a token's times around it. *)
let now =
  match Ptime.of_float_s 1792756800. with
  | Some t -> t
  | None -> Alcotest.fail "no instant"

let at seconds = Printf.sprintf "%.0f" (Ptime.to_float_s now +. seconds)

let claims ?(iss = issuer) ?(aud = Printf.sprintf "%S" resource)
    ?(exp = at 300.) ?nbf ?(scope = "notes:read") ?(drop = []) () =
  let members =
    [
      ("iss", Printf.sprintf "%S" iss);
      ("aud", aud);
      ("sub", {|"ada"|});
      ("client_id", {|"notes-app"|});
      ("iat", at (-60.));
      ("exp", exp);
      ("jti", {|"t-1"|});
      ("scope", Printf.sprintf "%S" scope);
    ]
    @ match nbf with Some n -> [ ("nbf", n) ] | None -> []
  in
  "{"
  ^ String.concat ","
      (List.filter_map
         (fun (name, v) ->
           if List.mem name drop then None
           else Some (Printf.sprintf "%S:%s" name v))
         members)
  ^ "}"

let token ?(typ = Some "at+jwt") ?(kid = "k1") ?(alg = "EdDSA") payload =
  let typ =
    match typ with Some t -> Printf.sprintf {|,"typ":"%s"|} t | None -> ""
  in
  ed_signed (Printf.sprintf {|{"alg":"%s","kid":"%s"%s}|} alg kid typ) payload

let me =
  Spindle.get
    Spindle.Path.(s "me")
    (Spindle.Returns.json Wiretype.string)
    (let+ (c : Bearer.claims) = Bearer.claims auth in
     Ok c.subject)

let notes =
  Spindle.get
    Spindle.Path.(s "notes")
    (Spindle.Returns.json Wiretype.string)
    (let+ () = Bearer.scope auth "notes:read" in
     Ok "Write to Charles")

let routes = [ me; notes ]

let app () =
  Spindle.Test.app
    ~resources:
      [
        Spindle.Dep.resource (Bearer.keys auth) (fun ~kid:_ ->
            [ key (ed_jwk ~kid:"k1" ()) ]);
      ]
    (routes @ [ Bearer.metadata auth routes ])

let get ?token path =
  let headers =
    match token with
    | Some t -> [ ("authorization", "Bearer " ^ t) ]
    | None -> []
  in
  Spindle.Test.call ~now ~headers (app ()) `GET path

let get_with headers path = Spindle.Test.call ~now ~headers (app ()) `GET path

let check_status name expected (r : Spindle.Test.response) =
  Alcotest.(check int) name expected (Spindle.Status.to_int r.status)

let challenge (r : Spindle.Test.response) =
  Option.value ~default:"" (Spindle.Test.header r "www-authenticate")

let check_invalid_token name t =
  let r = get ~token:t "/me" in
  check_status name 401 r;
  check_string (name ^ ", challenged")
    (Printf.sprintf {|Bearer error="invalid_token", resource_metadata="%s"|}
       metadata_url)
    (challenge r)

(* RFC 6750 §2.1: the token in Authorization, its scheme without case. *)
let test_a_token_in_authorization_is_read () =
  let r = get ~token:(token (claims ())) "/me" in
  check_status "200" 200 r;
  check_string "its subject" {|"ada"|} r.body;
  check_status "bearer in lower case" 200
    (get_with [ ("authorization", "bearer " ^ token (claims ())) ] "/me")

(* RFC 6750 §3 and RFC 9728 §5.1: a request with no bearer token is a 401
   that names how to get one and where to read about it, with no error
   code. *)
let test_no_token_is_challenged () =
  let r = get "/me" in
  check_status "401" 401 r;
  check_string "the challenge"
    (Printf.sprintf {|Bearer resource_metadata="%s"|} metadata_url)
    (challenge r);
  let basic = get_with [ ("authorization", "Basic YWRhOnB3") ] "/me" in
  check_status "another scheme is no bearer token" 401 basic;
  check_string "and is challenged alike"
    (Printf.sprintf {|Bearer resource_metadata="%s"|} metadata_url)
    (challenge basic)

(* RFC 6750 §2.3 and MCP: a token is read from Authorization alone. *)
let test_a_token_in_the_query_is_not_read () =
  check_status "401" 401 (get ("/me?access_token=" ^ token (claims ())))

(* RFC 6750 §3.1: a malformed request is a 400 invalid_request. *)
let test_a_malformed_authorization_is_invalid_request () =
  let r = get_with [ ("authorization", {|Bearer token="abc"|}) ] "/me" in
  check_status "400" 400 r;
  check_string "the challenge"
    (Printf.sprintf {|Bearer error="invalid_request", resource_metadata="%s"|}
       metadata_url)
    (challenge r)

(* RFC 6750 §3.1 and RFC 9068 §4: every check a token fails is
   invalid_token. *)
let test_a_token_that_fails_a_check_is_invalid () =
  let good = token (claims ()) in
  (* The signature's first character, which carries six of its bits, made
     one it is not: the key is new each run, so a fixed text could be the
     signature itself. *)
  let changed =
    let at = String.rindex good '.' + 1 in
    String.mapi
      (fun i c -> if i = at then if Char.equal c 'A' then 'B' else 'A' else c)
      good
  in
  check_invalid_token "a signature changed" changed;
  check_invalid_token "no JWS" "not-a-jwt";
  check_invalid_token "a kid the issuer has not" (token ~kid:"k2" (claims ()));
  check_invalid_token "alg none" (token ~alg:"none" (claims ()))

let test_typ_is_at_jwt () =
  check_invalid_token "typ JWT" (token ~typ:(Some "JWT") (claims ()));
  check_invalid_token "no typ" (token ~typ:None (claims ()));
  check_status "application/at+jwt" 200
    (get ~token:(token ~typ:(Some "application/at+jwt") (claims ())) "/me");
  check_status "AT+JWT, compared without case" 200
    (get ~token:(token ~typ:(Some "AT+JWT") (claims ())) "/me")

(* RFC 9068 §4: iss is the issuer's identifier, exactly. *)
let test_iss_is_the_issuer () =
  check_invalid_token "another issuer"
    (token (claims ~iss:"https://evil.example.com" ()));
  check_invalid_token "a trailing slash" (token (claims ~iss:(issuer ^ "/") ()))

(* RFC 8707 §2 and RFC 9068 §4: aud names this resource; a token for another
   is never accepted here. *)
let test_aud_names_this_resource () =
  check_invalid_token "another resource"
    (token (claims ~aud:{|"https://other.example.com"|} ()));
  check_status "among others" 200
    (get
       ~token:
         (token
            (claims
               ~aud:
                 (Printf.sprintf {|["https://other.example.com",%S]|} resource)
               ()))
       "/me");
  check_invalid_token "an array without it"
    (token (claims ~aud:{|["https://other.example.com"]|} ()))

(* RFC 7519 §4.1.4 and §4.1.5: not after exp, not before nbf. *)
let test_exp_and_nbf_bound_it () =
  check_invalid_token "expired" (token (claims ~exp:(at (-1.)) ()));
  check_invalid_token "expiring now" (token (claims ~exp:(at 0.) ()));
  check_invalid_token "not yet" (token (claims ~nbf:(at 60.) ()));
  check_status "nbf passed" 200
    (get ~token:(token (claims ~nbf:(at (-1.)) ())) "/me")

(* RFC 9068 §2.2: iss, exp, aud, sub, client_id, iat and jti are
   required. *)
let test_the_required_claims_are_there () =
  List.iter
    (fun name ->
      check_invalid_token ("no " ^ name) (token (claims ~drop:[ name ] ())))
    [ "iss"; "exp"; "aud"; "sub"; "client_id"; "iat"; "jti" ]

(* RFC 6750 §3.1: a token without the scope a route needs is a 403 that names
   it. *)
let test_a_missing_scope_is_insufficient_scope () =
  let r =
    get ~token:(token (claims ~scope:"notes:write profile" ())) "/notes"
  in
  check_status "403" 403 r;
  check_string "the challenge"
    (Printf.sprintf
       {|Bearer error="insufficient_scope", scope="notes:read", resource_metadata="%s"|}
       metadata_url)
    (challenge r);
  check_status "among others" 200
    (get ~token:(token (claims ~scope:"profile notes:read" ())) "/notes");
  check_status "no token is still a 401" 401 (get "/notes")

(* RFC 9728 §3: the metadata document, at the well-known path the resource's
   own is inserted after. *)
let test_the_metadata_document () =
  let r = get "/.well-known/oauth-protected-resource/mcp" in
  check_status "200" 200 r;
  check_string "its members"
    (Printf.sprintf
       {|{"resource":"%s","authorization_servers":["%s"],"scopes_supported":["notes:read"],"bearer_methods_supported":["header"]}|}
       resource issuer)
    r.body

let test_a_resource_with_no_path () =
  let auth = Bearer.make ~issuer ~resource:"https://api.example.com" in
  let r =
    Spindle.Test.call ~now
      (Spindle.Test.app [ Bearer.metadata auth [] ])
      `GET "/.well-known/oauth-protected-resource"
  in
  check_status "200" 200 r

(* The API's document names the scheme and each route's scopes. *)
let test_the_document_names_the_scopes () =
  let doc =
    match Spindle.App.make routes with
    | Error m -> Alcotest.fail m
    | Ok a -> (
        match Spindle.Openapi.document ~title:"Notes" a with
        | Ok text -> Yojson.Safe.from_string text
        | Error e -> Alcotest.failf "no document: %s" (String.concat "; " e))
  in
  let security path =
    Yojson.Safe.to_string
      (List.fold_left
         (fun j k -> Yojson.Safe.Util.member k j)
         doc
         [ "paths"; path; "get"; "security" ])
  in
  check_string "notes needs notes:read" {|[{"bearer":["notes:read"]}]|}
    (security "/notes");
  check_string "me needs a token" {|[{"bearer":[]}]|} (security "/me")

(* A secret has no span: no token, accepted or refused, is in any line
   logged, at any level, while a refusal's line says which check failed. *)
let test_no_token_is_logged () =
  let lines = ref [] in
  Spindle.Log.setup ~format:Spindle.Log.Json ~level:(Some Logs.Debug)
    ~out:(fun l -> lines := l :: !lines)
    ();
  let good = token (claims ())
  and expired = token (claims ~exp:(at (-1.)) ()) in
  check_status "accepted" 200 (get ~token:good "/me");
  check_status "expired" 401 (get ~token:expired "/me");
  check_status "in the query" 401 (get ("/me?access_token=" ^ good));
  let contains ~sub l =
    let n = String.length sub in
    let rec at i =
      i + n <= String.length l
      && (String.equal (String.sub l i n) sub || at (i + 1))
    in
    at 0
  in
  (* A token's signature is its own: a header or a payload alone could be
     another's. *)
  let signature t =
    match List.rev (String.split_on_char '.' t) with s :: _ -> s | [] -> t
  in
  List.iter
    (fun (name, t) ->
      check_bool name false (List.exists (contains ~sub:(signature t)) !lines))
    [ ("the accepted token", good); ("the expired token", expired) ];
  check_bool "the refusal says why" true
    (List.exists (contains ~sub:"expired") !lines)

(* RFC 8414 §2 and RFC 9728 §1.2: both are https URLs with no fragment. *)
let test_make_refuses_what_is_no_https_url () =
  List.iter
    (fun (name, issuer, resource) ->
      check_bool name true
        (match Bearer.make ~issuer ~resource with
        | _ -> false
        | exception Invalid_argument _ -> true))
    [
      ("an http issuer", "http://id.example.com", resource);
      ("an issuer with a query", issuer ^ "?x=1", resource);
      ("an http resource", issuer, "http://api.example.com");
      ("a resource with a fragment", issuer, resource ^ "#x");
      ("no URL", "id.example.com", resource);
    ];
  check_bool "a scope with a space" true
    (match Bearer.scope auth "notes read" with
    | _ -> false
    | exception Invalid_argument _ -> true)

(* ------------------------------------------------------------------ *)
(* The issuer's keys, found as RFC 8414 says *)

(* An issuer over TLS, answering as [respond] says, given its own base URL,
   to a client on a clock the test moves. *)
let with_issuer respond f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port, start = Stub_server.listen ~sw ~net in
  let front, authenticator = Tls_front.listen ~sw ~net ~port in
  let base = Printf.sprintf "https://localhost:%d" front in
  let asked = ref [] in
  start (fun (r : Stub_server.request) ->
      asked := r.path :: !asked;
      respond ~base r);
  let clock = Eio_mock.Clock.Mono.make () in
  (* [run] closes every connection it kept when [f] returns, so the front's
     fibers end and the switch can. *)
  Spindle_client.run ~authenticator
    object
      method net = net
      method mono_clock = clock
    end
  @@ fun client -> f ~base ~clock ~asked:(fun () -> List.rev !asked) client

let json body =
  Stub_server.reply ~headers:[ ("content-type", "application/json") ] `OK body

let not_found = Stub_server.reply `Not_found ""

let metadata_of ~issuer ~base =
  json (Printf.sprintf {|{"issuer":%S,"jwks_uri":"%s/jwks"}|} issuer base)

let set_of keys =
  json (Printf.sprintf {|{"keys":[%s]}|} (String.concat "," keys))

let kids keys = List.map (fun k -> Option.value ~default:"" (Jwk.kid k)) keys

let check_kids name expected keys =
  Alcotest.(check (list string)) name expected (kids keys)

(* RFC 8414 §3.1: the well-known name goes before the issuer's path. *)
let test_the_metadata_is_found_before_the_path () =
  with_issuer
    (fun ~base (r : Stub_server.request) ->
      match r.path with
      | "/.well-known/oauth-authorization-server/tenant" ->
          metadata_of ~issuer:(base ^ "/tenant") ~base
      | "/jwks" -> set_of [ ed_jwk ~kid:"k1" () ]
      | _ -> not_found)
    (fun ~base ~clock:_ ~asked client ->
      let keys = Spindle_client.Oauth.keys client ~issuer:(base ^ "/tenant") in
      check_kids "its key" [ "k1" ] (keys ~kid:None);
      Alcotest.(check (list string))
        "what was asked"
        [ "/.well-known/oauth-authorization-server/tenant"; "/jwks" ]
        (asked ()))

(* MCP's order: RFC 8414's name, then OpenID Connect's before the path, then
   after it (OpenID Connect Discovery §4). *)
let test_openid_configuration_is_tried_after () =
  with_issuer
    (fun ~base (r : Stub_server.request) ->
      match r.path with
      | "/tenant/.well-known/openid-configuration" ->
          metadata_of ~issuer:(base ^ "/tenant") ~base
      | "/jwks" -> set_of [ ed_jwk ~kid:"k1" () ]
      | _ -> not_found)
    (fun ~base ~clock:_ ~asked client ->
      let keys = Spindle_client.Oauth.keys client ~issuer:(base ^ "/tenant") in
      check_kids "its key" [ "k1" ] (keys ~kid:None);
      Alcotest.(check (list string))
        "each in turn"
        [
          "/.well-known/oauth-authorization-server/tenant";
          "/.well-known/openid-configuration/tenant";
          "/tenant/.well-known/openid-configuration";
          "/jwks";
        ]
        (asked ()))

(* RFC 8414 §3.3: metadata naming another issuer is not used. *)
let test_metadata_of_another_issuer_is_not_used () =
  with_issuer
    (fun ~base (r : Stub_server.request) ->
      match r.path with
      | "/.well-known/oauth-authorization-server" ->
          metadata_of ~issuer:"https://evil.example.com" ~base
      | "/jwks" -> set_of [ ed_jwk ~kid:"k1" () ]
      | _ -> not_found)
    (fun ~base ~clock:_ ~asked client ->
      let keys = Spindle_client.Oauth.keys client ~issuer:base in
      check_kids "no keys" [] (keys ~kid:None);
      check_bool "its keys never fetched" false
        (List.exists (String.equal "/jwks") (asked ())))

let minute_and_a_second = Mtime.of_uint64_ns 61_000_000_000L

(* A kid the kept keys lack fetches them again, at most once a minute. *)
let test_an_unknown_kid_fetches_again_once_a_minute () =
  let served = ref [ ed_jwk ~kid:"k1" () ] in
  with_issuer
    (fun ~base (r : Stub_server.request) ->
      match r.path with
      | "/.well-known/oauth-authorization-server" ->
          metadata_of ~issuer:base ~base
      | "/jwks" -> set_of !served
      | _ -> not_found)
    (fun ~base ~clock ~asked client ->
      let keys = Spindle_client.Oauth.keys client ~issuer:base in
      let fetches () =
        List.length (List.filter (String.equal "/jwks") (asked ()))
      in
      check_kids "k1" [ "k1" ] (keys ~kid:(Some "k1"));
      served := [ ed_jwk ~kid:"k1" (); ed_jwk ~kid:"k2" () ];
      check_kids "k2, within the minute" [] (keys ~kid:(Some "k2"));
      Alcotest.(check int) "one fetch" 1 (fetches ());
      Eio_mock.Clock.Mono.set_time clock minute_and_a_second;
      check_kids "k2, a minute on" [ "k2" ] (keys ~kid:(Some "k2"));
      check_kids "k3, just fetched" [] (keys ~kid:(Some "k3"));
      Alcotest.(check int) "two fetches" 2 (fetches ());
      Alcotest.(check int)
        "the metadata once" 1
        (List.length
           (List.filter
              (String.equal "/.well-known/oauth-authorization-server")
              (asked ()))))

(* A fetch that fails leaves no keys, and is tried again a minute on. *)
let test_a_failed_fetch_is_tried_again () =
  let up = ref false in
  with_issuer
    (fun ~base (r : Stub_server.request) ->
      match r.path with
      | "/.well-known/oauth-authorization-server" ->
          metadata_of ~issuer:base ~base
      | "/jwks" ->
          if !up then set_of [ ed_jwk ~kid:"k1" () ]
          else Stub_server.reply `Internal_server_error ""
      | _ -> not_found)
    (fun ~base ~clock ~asked:_ client ->
      let keys = Spindle_client.Oauth.keys client ~issuer:base in
      check_kids "none while it fails" [] (keys ~kid:(Some "k1"));
      up := true;
      check_kids "none within the minute" [] (keys ~kid:(Some "k1"));
      Eio_mock.Clock.Mono.set_time clock minute_and_a_second;
      check_kids "k1, a minute on" [ "k1" ] (keys ~kid:(Some "k1")))

(* ------------------------------------------------------------------ *)
(* An authorization server that is not ours *)

(* node-oidc-provider, as test/oidc/issuer.mjs runs it, from the directory
   SPINDLE_TEST_OIDC names -- which `make test` sets once its packages are
   installed. Without it these rows are skipped, and the output says so. *)
let oidc_dir = Sys.getenv_opt "SPINDLE_TEST_OIDC"

(* One issuer for every row, started when the first needs it and ended as
   the suite exits, by closing its input. *)
let provider =
  lazy
    (match oidc_dir with
    | None -> Alcotest.fail "SPINDLE_TEST_OIDC is not set"
    | Some dir ->
        let cert, key = Tls_front.pem Name_only in
        let file contents =
          let path = Filename.temp_file "spindle-oidc" ".pem" in
          Out_channel.with_open_bin path (fun oc ->
              Out_channel.output_string oc contents);
          path
        in
        let cert = file cert and key = file key in
        let stdin_r, stdin_w = Unix.pipe ~cloexec:true () in
        let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
        let (_ : int) =
          Unix.create_process "bun"
            [| "bun"; Filename.concat dir "issuer.mjs"; cert; key |]
            stdin_r stdout_w Unix.stderr
        in
        Unix.close stdin_r;
        Unix.close stdout_w;
        at_exit (fun () -> Unix.close stdin_w);
        let port =
          match In_channel.input_line (Unix.in_channel_of_descr stdout_r) with
          | Some line -> line
          | None -> Alcotest.fail "the issuer printed no port"
        in
        Printf.sprintf "https://localhost:%s" port)

let with_provider f =
  let issuer = Lazy.force provider in
  Eio_main.run @@ fun env ->
  let _, authenticator = Tls_front.certificate Name_only in
  Spindle_client.run ~authenticator env @@ fun client -> f ~issuer client

(* RFC 6749 §4.4: the client credentials grant, with RFC 8707's resource
   naming the audience. *)
let issued client ~issuer ~resource ~scope =
  let body =
    Spindle_http.Urlencoded.to_string
      [
        ("grant_type", "client_credentials");
        ("scope", scope);
        ("resource", resource);
      ]
  in
  match
    Spindle_client.call client
      ~headers:
        [
          ("content-type", "application/x-www-form-urlencoded");
          ( "authorization",
            "Basic "
            ^ Base64.encode_string "spindle-test:a-secret-the-suite-knows" );
        ]
      ~body `POST (issuer ^ "/token")
  with
  | Error e -> Alcotest.failf "no token: %s" (Spindle_client.error_to_string e)
  | Ok { status = `OK; body; _ } ->
      Yojson.Safe.Util.(
        to_string (member "access_token" (Yojson.Safe.from_string body)))
  | Ok { status; body; _ } ->
      Alcotest.failf "the token endpoint answered %d: %s"
        (Spindle.Status.to_int status)
        body

(* A server for [resource], its keys fetched from the issuer's metadata, as an
   application's would be, called with [token]. *)
let called client ~issuer ~resource ~token path =
  let auth = Bearer.make ~issuer ~resource in
  let routes =
    [
      Spindle.get
        Spindle.Path.(s "me")
        (Spindle.Returns.json Wiretype.string)
        (let+ (c : Bearer.claims) = Bearer.claims auth in
         Ok c.subject);
      Spindle.get
        Spindle.Path.(s "notes")
        (Spindle.Returns.json Wiretype.string)
        (let+ () = Bearer.scope auth "notes:read" in
         Ok "Write to Charles");
    ]
  in
  let app =
    Spindle.Test.app
      ~resources:
        [
          Spindle.Dep.resource (Bearer.keys auth)
            (Spindle_client.Oauth.keys client ~issuer);
        ]
      routes
  in
  Spindle.Test.call ~now:(Ptime_clock.now ())
    ~headers:[ ("authorization", "Bearer " ^ token) ]
    app `GET path

let resource_for alg = "https://api.example.com/" ^ alg

(* RFC 9068 §4: each kind of key the issuer signs with is checked. *)
let test_the_issuers_tokens_are_accepted () =
  with_provider @@ fun ~issuer client ->
  List.iter
    (fun alg ->
      let resource = resource_for alg in
      let token = issued client ~issuer ~resource ~scope:"notes:read" in
      let r = called client ~issuer ~resource ~token "/me" in
      check_status alg 200 r;
      check_string (alg ^ ", its client") {|"spindle-test"|} r.body)
    [ "es256"; "rsa"; "ed25519" ]

(* RFC 8707 §2: a token the issuer made for another resource is refused. *)
let test_a_token_for_another_resource_is_refused () =
  with_provider @@ fun ~issuer client ->
  let token =
    issued client ~issuer ~resource:(resource_for "other") ~scope:"notes:read"
  in
  check_status "401" 401
    (called client ~issuer ~resource:(resource_for "es256") ~token "/me")

(* RFC 6750 §3.1: a scope the issuer did not grant is a 403. *)
let test_a_scope_not_granted_is_insufficient () =
  with_provider @@ fun ~issuer client ->
  let resource = resource_for "es256" in
  let token = issued client ~issuer ~resource ~scope:"notes:write" in
  check_status "403" 403 (called client ~issuer ~resource ~token "/notes");
  let token = issued client ~issuer ~resource ~scope:"notes:read" in
  check_status "200" 200 (called client ~issuer ~resource ~token "/notes")

(* RFC 9068 §4: a token the issuer signed is refused by a server that trusts
   another issuer, whose keys are not its. *)
let test_a_token_of_another_issuer_is_refused () =
  with_provider @@ fun ~issuer client ->
  let resource = resource_for "es256" in
  let token = issued client ~issuer ~resource ~scope:"notes:read" in
  let auth = Bearer.make ~issuer:"https://id.example.com" ~resource in
  let r =
    Spindle.Test.call ~now:(Ptime_clock.now ())
      ~headers:[ ("authorization", "Bearer " ^ token) ]
      (Spindle.Test.app
         ~resources:
           [
             Spindle.Dep.resource (Bearer.keys auth)
               (Spindle_client.Oauth.keys client ~issuer);
           ]
         [
           Spindle.get
             Spindle.Path.(s "me")
             (Spindle.Returns.json Wiretype.string)
             (let+ (c : Bearer.claims) = Bearer.claims auth in
              Ok c.subject);
         ])
      `GET "/me"
  in
  check_status "401" 401 r

let issuer_rows =
  match oidc_dir with
  | None ->
      print_endline
        "  [the issuer's rows skipped: no SPINDLE_TEST_OIDC -- set it to \
         test/oidc, its packages installed]";
      []
  | Some _ ->
      [
        ( "issuer",
          [
            Alcotest.test_case "9068 §4: the issuer's tokens are accepted"
              `Quick test_the_issuers_tokens_are_accepted;
            Alcotest.test_case
              "8707 §2: a token for another resource is refused" `Quick
              test_a_token_for_another_resource_is_refused;
            Alcotest.test_case "6750 §3.1: a scope not granted is insufficient"
              `Quick test_a_scope_not_granted_is_insufficient;
            Alcotest.test_case "9068 §4: another issuer's token is refused"
              `Quick test_a_token_of_another_issuer_is_refused;
          ] );
      ]

let () =
  Alcotest.run "oauth-rfc"
    ([
       ( "JOSE",
         [
           Alcotest.test_case "7515 A.2: the RS256 example verifies" `Quick
             test_rs256_example;
           Alcotest.test_case "7515 A.3: the ES256 example verifies" `Quick
             test_es256_example;
           Alcotest.test_case "8037 A.4: the EdDSA example verifies" `Quick
             test_eddsa_example;
           Alcotest.test_case "7515 §5.2: a key of another kind is not tried"
             `Quick test_a_key_of_another_kind_is_not_tried;
           Alcotest.test_case "7515 §5.2: alg none is refused" `Quick
             test_alg_none_is_refused;
           Alcotest.test_case "7515 §5.2: an HMAC is refused" `Quick
             test_hmac_is_refused;
           Alcotest.test_case "7515 §4.1.11: crit is refused" `Quick
             test_crit_is_refused;
           Alcotest.test_case "7515 §4: a header parameter twice is refused"
             `Quick test_a_header_parameter_twice_is_refused;
           Alcotest.test_case "7515 §4.1.1: a header without alg is refused"
             `Quick test_a_header_without_alg_is_refused;
           Alcotest.test_case "7515 §7.1: the compact form is read strictly"
             `Quick test_the_compact_form_is_read_strictly;
           test_any_character_changed_is_refused;
           Alcotest.test_case "7515 §4.1.4: a kid picks its key" `Quick
             test_a_kid_picks_its_key;
           Alcotest.test_case "7517 §4.4: a key's alg binds it" `Quick
             test_a_keys_alg_binds_it;
           Alcotest.test_case "7518 §3.3: a short RSA key is refused" `Quick
             test_a_short_rsa_key_is_refused;
           Alcotest.test_case
             "7518 §6.2.1: a P-256 key is its size, on the curve" `Quick
             test_a_p256_key_is_its_size_and_on_the_curve;
           Alcotest.test_case "7517 §4.2: a key for encryption is refused"
             `Quick test_a_key_for_encryption_is_refused;
           Alcotest.test_case "7517 §5: a set keeps the keys it reads" `Quick
             test_a_set_keeps_the_keys_it_reads;
         ] );
       ( "bearer",
         [
           Alcotest.test_case "6750 §2.1: a token in Authorization is read"
             `Quick test_a_token_in_authorization_is_read;
           Alcotest.test_case "6750 §3: no token is challenged" `Quick
             test_no_token_is_challenged;
           Alcotest.test_case "6750 §2.3: a token in the query is not read"
             `Quick test_a_token_in_the_query_is_not_read;
           Alcotest.test_case "6750 §3.1: a malformed header is invalid_request"
             `Quick test_a_malformed_authorization_is_invalid_request;
           Alcotest.test_case "6750 §3.1: a token failing a check is invalid"
             `Quick test_a_token_that_fails_a_check_is_invalid;
           Alcotest.test_case "9068 §4: typ is at+jwt" `Quick test_typ_is_at_jwt;
           Alcotest.test_case "9068 §4: iss is the issuer" `Quick
             test_iss_is_the_issuer;
           Alcotest.test_case "8707 §2: aud names this resource" `Quick
             test_aud_names_this_resource;
           Alcotest.test_case "7519 §4.1.4: exp and nbf bound it" `Quick
             test_exp_and_nbf_bound_it;
           Alcotest.test_case "9068 §2.2: the required claims are there" `Quick
             test_the_required_claims_are_there;
           Alcotest.test_case "6750 §3.1: a missing scope is insufficient_scope"
             `Quick test_a_missing_scope_is_insufficient_scope;
           Alcotest.test_case "9728 §3: the metadata document" `Quick
             test_the_metadata_document;
           Alcotest.test_case "9728 §3.1: a resource with no path" `Quick
             test_a_resource_with_no_path;
           Alcotest.test_case "the API's document names the scopes" `Quick
             test_the_document_names_the_scopes;
           Alcotest.test_case "a token is in no line logged" `Quick
             test_no_token_is_logged;
           Alcotest.test_case "8414 §2: make refuses what is no https URL"
             `Quick test_make_refuses_what_is_no_https_url;
         ] );
       ( "keys",
         [
           Alcotest.test_case "8414 §3.1: the metadata, before the path" `Quick
             test_the_metadata_is_found_before_the_path;
           Alcotest.test_case "8414 §3.1: openid-configuration, after" `Quick
             test_openid_configuration_is_tried_after;
           Alcotest.test_case "8414 §3.3: another issuer's metadata is not used"
             `Quick test_metadata_of_another_issuer_is_not_used;
           Alcotest.test_case "an unknown kid fetches again once a minute"
             `Quick test_an_unknown_kid_fetches_again_once_a_minute;
           Alcotest.test_case "a failed fetch is tried again" `Quick
             test_a_failed_fetch_is_tried_again;
         ] );
     ]
    @ issuer_rows)
