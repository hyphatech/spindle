(** Base64url without padding, as JOSE writes every part of a key and a
    signature (RFC 7515 §2). *)

val decode : string -> string option
(** The octets, where the text is base64url in its one canonical form: no
    padding, no character outside the alphabet, and the bits a last character
    leaves unused zero (RFC 4648 §3.5), so two texts never read as one value. *)
