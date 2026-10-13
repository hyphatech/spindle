module Sha = Digestif.SHA256
module Gcm = Mirage_crypto.AES.GCM

(* Four keys, so nothing one use makes is ever another's: a cookie's, made
   by the framework, apart from what the application signs or seals, which
   may be text a caller chose. *)
type t = {
  signing : string;
  sealing : Gcm.key;
  cookie_signing : string;
  cookie_sealing : Gcm.key;
}

type ring = { newest : t; all : t list }

let hmac ~key text = Sha.to_raw_string (Sha.hmac_string ~key text)

(* RFC 5869 HKDF with no salt and one block of output; the info names the
   key's purpose. *)
let derive secret info =
  let prk = hmac ~key:(String.make 32 '\000') secret in
  hmac ~key:prk (info ^ "\001")

let of_secret secret =
  if String.length secret < 32 then
    Error "A key's secret is at least 32 bytes, and this one is shorter."
  else
    Ok
      {
        signing = derive secret "spindle signing";
        sealing = Gcm.of_secret (derive secret "spindle sealing");
        cookie_signing = derive secret "spindle cookie signing";
        cookie_sealing = Gcm.of_secret (derive secret "spindle cookie sealing");
      }

let ring newest retired = { newest; all = newest :: retired }
let sign_with key r text = hmac ~key:(key r.newest) text

(* Checked for length first, since reading another length as a digest
   raises. *)
let verify_with key r ~mac text =
  String.length mac = Sha.digest_size
  && List.exists
       (fun k ->
         Sha.equal
           (Sha.of_raw_string (hmac ~key:(key k) text))
           (Sha.of_raw_string mac))
       r.all

let nonce_bytes = 12

let seal_with key r ~adata text =
  let nonce = Mirage_crypto_rng_unix.getrandom nonce_bytes in
  nonce ^ Gcm.authenticate_encrypt ~key:(key r.newest) ~nonce ~adata text

let unseal_with key r ~adata sealed =
  if String.length sealed < nonce_bytes + Gcm.tag_size then None
  else
    let nonce = String.sub sealed 0 nonce_bytes in
    let body =
      String.sub sealed nonce_bytes (String.length sealed - nonce_bytes)
    in
    List.find_map
      (fun k -> Gcm.authenticate_decrypt ~key:(key k) ~nonce ~adata body)
      r.all

let sign = sign_with (fun k -> k.signing)
let verify = verify_with (fun k -> k.signing)
let seal = seal_with (fun k -> k.sealing)
let unseal = unseal_with (fun k -> k.sealing)
let sign_cookie = sign_with (fun k -> k.cookie_signing)
let verify_cookie = verify_with (fun k -> k.cookie_signing)
let seal_cookie = seal_with (fun k -> k.cookie_sealing)
let unseal_cookie = unseal_with (fun k -> k.cookie_sealing)
