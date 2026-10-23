(** Public keys as RFC 7517 writes them, of the kinds a signature is checked
    with here: RSA (RFC 7518 §6.3) of 2048 bits or more, which RFC 7518 §3.3
    requires of RS256; EC on P-256 (RFC 7518 §6.2); and OKP on Ed25519 (RFC 8037
    §2). A private member a key carries is not read.

    {[
    match Jwk.set_of_string body with
    | Ok keys -> Jws.verify jws ~keys
    | Error why -> ...
    ]} *)

type t
(** A public key, read and checked: its numbers are a key of its kind. *)

type kind =
  | Rsa  (** checks RS256 *)
  | P256  (** checks ES256 *)
  | Ed25519  (** checks EdDSA *)

val kind : t -> kind

val kid : t -> string option
(** Its ["kid"]: which key of a set a JWS names. *)

val alg : t -> string option
(** Its ["alg"], where it names the one algorithm it is for (RFC 7517 §4.4). *)

val of_string : string -> (t, string) result
(** One key, as JSON. An [Error] says in words why it is no key of these kinds
    -- another ["kty"] or curve, a member its kind requires missing, a number
    that is not one, an RSA modulus under 2048 bits, a ["use"] other than
    ["sig"] -- and quotes nothing of it. *)

val verify : t -> signature:string -> string -> bool
(** [verify t ~signature input]: whether [signature] signs [input] under [t], by
    its kind's algorithm -- RS256, ES256 with [signature] its 64 octets [R || S]
    (RFC 7518 §3.4), or EdDSA. *)

val set_of_string : string -> (t list, string) result
(** A JWK Set, [{"keys": [...]}]: its keys this module reads, in order. A key
    {!of_string} refuses is left out, as RFC 7517 §5 asks of a key whose kind,
    members or values are not understood; an [Error] is a document that is no
    JWK Set. *)
