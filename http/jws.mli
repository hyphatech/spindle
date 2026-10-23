(** JSON Web Signatures in the compact serialization (RFC 7515 §7.1): a header,
    a payload and a signature, checked against public keys ({!Jwk}) by RS256,
    ES256 or EdDSA. No other algorithm is checked: ["none"] signs nothing, and
    an HMAC's key is a secret both ends hold, which a public key set never is.

    {[
    let* jws = Jws.of_string token in
    let* payload = Jws.verify jws ~keys in
    ...
    ]} *)

type t
(** A JWS read, its signature not yet checked. *)

type error =
  | Malformed of string
      (** not three base64url parts, or a header that is no JSON object of what
          RFC 7515 §4.1 asks; in words, quoting nothing *)
  | Unsupported_algorithm of string  (** an ["alg"] other than the three *)
  | Critical of string list
      (** a ["crit"]: RFC 7515 §4.1.11 has a reader refuse every extension it
          does not understand, and this one understands none *)
  | No_key
      (** no key of the [alg]'s kind, and of the ["kid"] where one is named *)
  | Bad_signature

val error_to_string : error -> string

val of_string : string -> (t, error) result
(** A compact JWS: each part base64url without padding, the header a JSON object
    naming ["alg"], no member given twice (RFC 7515 §4). The payload is not
    read. *)

val alg : t -> string
val kid : t -> string option

val typ : t -> string option
(** The header's ["typ"], as written: a media type, compared without case. *)

val verify : t -> keys:Jwk.t list -> (string, error) result
(** The payload, once the signature checks under one of [keys]: those of the
    [alg]'s kind, whose own ["alg"] is absent or the same, and whose ["kid"] is
    the header's where the header names one. *)
