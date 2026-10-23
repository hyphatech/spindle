type t = {
  alg : string;
  kid : string option;
  typ : string option;
  input : string;  (** what was signed: the first two parts as sent *)
  payload : string;
  signature : string;
}

type error =
  | Malformed of string
  | Unsupported_algorithm of string
  | Critical of string list
  | No_key
  | Bad_signature

let error_to_string = function
  | Malformed why -> "a malformed JWS: " ^ why
  | Unsupported_algorithm alg ->
      Printf.sprintf "alg %S is none this server checks" alg
  | Critical names ->
      Printf.sprintf "crit names %s, which this server does not understand"
        (String.concat ", " names)
  | No_key -> "no key the JWS could be signed with"
  | Bad_signature -> "the signature does not check"

type header = {
  alg : string;
  kid : string option;
  typ : string option;
  crit : string list option;
}

let header_json =
  Wiretype.Object.(
    map (fun alg kid typ crit -> { alg; kid; typ; crit })
    |> mem "alg" Wiretype.string
    |> opt_mem "kid" Wiretype.string
    |> opt_mem "typ" Wiretype.string
    |> opt_mem "crit" (Wiretype.list Wiretype.string)
    |> finish)

let ( let* ) = Result.bind

let part name text =
  Option.to_result (Base64url.decode text)
    ~none:(Malformed (name ^ " is not base64url"))

let of_string s =
  match String.split_on_char '.' s with
  | [ h; p; sg ] -> (
      let* header_text = part "the header" h in
      let* payload = part "the payload" p in
      let* signature = part "the signature" sg in
      match Wiretype.decode header_json header_text with
      | Error _ -> Error (Malformed "the header is no JSON object naming alg")
      (* RFC 7515 §4.1.11: crit, where present, is never empty. *)
      | Ok { crit = Some []; _ } -> Error (Malformed "crit is empty")
      | Ok { crit = Some names; _ } -> Error (Critical names)
      | Ok { alg; kid; typ; crit = None } ->
          Ok { alg; kid; typ; input = h ^ "." ^ p; payload; signature })
  | _ -> Error (Malformed "not three parts")

let alg (t : t) = t.alg
let kid (t : t) = t.kid
let typ (t : t) = t.typ

let kind_of_alg = function
  | "RS256" -> Some Jwk.Rsa
  | "ES256" -> Some Jwk.P256
  | "EdDSA" -> Some Jwk.Ed25519
  | _ -> None

let same_kind (a : Jwk.kind) (b : Jwk.kind) =
  match (a, b) with
  | Rsa, Rsa | P256, P256 | Ed25519, Ed25519 -> true
  | (Rsa | P256 | Ed25519), _ -> false

let verify (t : t) ~keys =
  match kind_of_alg t.alg with
  | None -> Error (Unsupported_algorithm t.alg)
  | Some kind -> (
      let usable k =
        same_kind (Jwk.kind k) kind
        && Option.fold ~none:true ~some:(String.equal t.alg) (Jwk.alg k)
        && Option.fold ~none:true
             ~some:(fun kid -> Option.equal String.equal (Jwk.kid k) (Some kid))
             t.kid
      in
      match List.filter usable keys with
      | [] -> Error No_key
      | candidates ->
          if
            List.exists
              (fun k -> Jwk.verify k ~signature:t.signature t.input)
              candidates
          then Ok t.payload
          else Error Bad_signature)
