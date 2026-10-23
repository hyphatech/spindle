module Ec = Mirage_crypto_ec
module Pk = Mirage_crypto_pk

type kind = Rsa | P256 | Ed25519

type key =
  | Rsa_key of Pk.Rsa.pub
  | P256_key of Ec.P256.Dsa.pub
  | Ed25519_key of Ec.Ed25519.pub

type t = { key : key; kid : string option; alg : string option }

let kind t =
  match t.key with
  | Rsa_key _ -> Rsa
  | P256_key _ -> P256
  | Ed25519_key _ -> Ed25519

let kid t = t.kid
let alg t = t.alg

(* Every member any of the three kinds has, each read where its kind needs
   it; a private key's are not described, so they are skipped. *)
type members = {
  kty : string;
  crv : string option;
  n : string option;
  e : string option;
  x : string option;
  y : string option;
  kid : string option;
  alg : string option;
  use : string option;
  key_ops : string list option;
}

let members_json =
  Wiretype.Object.(
    map (fun kty crv n e x y kid alg use key_ops ->
        { kty; crv; n; e; x; y; kid; alg; use; key_ops })
    |> mem "kty" Wiretype.string
    |> opt_mem "crv" Wiretype.string
    |> opt_mem "n" Wiretype.string
    |> opt_mem "e" Wiretype.string
    |> opt_mem "x" Wiretype.string
    |> opt_mem "y" Wiretype.string
    |> opt_mem "kid" Wiretype.string
    |> opt_mem "alg" Wiretype.string
    |> opt_mem "use" Wiretype.string
    |> opt_mem "key_ops" (Wiretype.list Wiretype.string)
    |> finish)

let ( let* ) = Result.bind

let octets name = function
  | None -> Error (Printf.sprintf "no %S" name)
  | Some text ->
      Option.to_result (Base64url.decode text)
        ~none:(Printf.sprintf "%S is not base64url" name)

let sized name size v =
  let* o = octets name v in
  if String.length o = size then Ok o
  else Error (Printf.sprintf "%S is not %d octets" name size)

(* RFC 7518 §2: a Base64urlUInt is the fewest octets that hold the number. *)
let unsigned name v =
  let* o = octets name v in
  if String.length o > 0 && not (Char.equal o.[0] '\x00') then
    Ok (Pk.Z_extra.of_octets_be o)
  else Error (Printf.sprintf "%S is not a number in its fewest octets" name)

(* RFC 7518 §3.3. *)
let rsa_minimum_bits = 2048

let key_of (m : members) =
  match (m.kty, m.crv) with
  | "RSA", _ ->
      let* n = unsigned "n" m.n in
      let* e = unsigned "e" m.e in
      let* pub =
        Result.map_error (fun _ -> "no RSA public key") (Pk.Rsa.pub ~e ~n)
      in
      if Pk.Rsa.pub_bits pub >= rsa_minimum_bits then Ok (Rsa_key pub)
      else Error "an RSA modulus under 2048 bits"
  | "EC", Some "P-256" ->
      let* x = sized "x" 32 m.x in
      let* y = sized "y" 32 m.y in
      (* SEC 1 §2.3.3: an uncompressed point. *)
      Result.map
        (fun pub -> P256_key pub)
        (Result.map_error
           (fun _ -> "no point on P-256")
           (Ec.P256.Dsa.pub_of_octets ("\x04" ^ x ^ y)))
  | "OKP", Some "Ed25519" ->
      let* x = sized "x" 32 m.x in
      Result.map
        (fun pub -> Ed25519_key pub)
        (Result.map_error
           (fun _ -> "no Ed25519 public key")
           (Ec.Ed25519.pub_of_octets x))
  | ("EC" | "OKP"), _ -> Error "a curve other than P-256 or Ed25519"
  | _ -> Error "a kty other than RSA, EC or OKP"

(* RFC 7517 §4.2 and §4.3: a key meant for anything but signatures is not
   one to check a signature with. *)
let for_signatures (m : members) =
  let use = match m.use with None | Some "sig" -> true | Some _ -> false in
  let ops =
    match m.key_ops with
    | None -> true
    | Some ops -> List.exists (String.equal "verify") ops
  in
  if use && ops then Ok () else Error "a key not for checking signatures"

let of_members (m : members) =
  let* () = for_signatures m in
  let* key = key_of m in
  Ok { key; kid = m.kid; alg = m.alg }

let of_string s =
  match Wiretype.decode members_json s with
  | Error _ -> Error "no JSON object naming a kty"
  | Ok m -> of_members m

let verify t ~signature input =
  match t.key with
  | Rsa_key key ->
      String.length signature = (Pk.Rsa.pub_bits key + 7) / 8
      && Pk.Rsa.PKCS1.verify
           ~hashp:(function `SHA256 -> true | _ -> false)
           ~key ~signature (`Message input)
  | P256_key key ->
      String.length signature = 64
      && Ec.P256.Dsa.verify ~key
           (String.sub signature 0 32, String.sub signature 32 32)
           (Digestif.SHA256.to_raw_string (Digestif.SHA256.digest_string input))
  | Ed25519_key key -> Ec.Ed25519.verify ~key signature ~msg:input

(* Each key is read as JSON of its own, so one that is not understood is
   left out rather than failing the set. *)
let set_json =
  Wiretype.Object.(
    map Fun.id |> mem "keys" (Wiretype.list Wiretype.Value.json) |> finish)

let set_of_string s =
  match Wiretype.decode set_json s with
  | Error _ -> Error "no JSON object with a keys array"
  | Ok keys ->
      Ok
        (List.filter_map
           (fun v ->
             match Wiretype.of_value members_json v with
             | Error _ -> None
             | Ok m -> Result.to_option (of_members m))
           keys)
