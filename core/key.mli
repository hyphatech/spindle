(** The keys a signed or an encrypted cookie is made with ({!Spindle.Cookie}).

    {[
    match Spindle.Key.of_secret (Sys.getenv "COOKIE_SECRET") with
    | Ok key -> routes (Spindle.Key.ring key [])
    | Error sentence -> ...
    ]}

    {b A secret is the application's to read}, when it starts: the framework
    reads no environment. One secret serves both uses -- two keys are derived
    from it with HKDF-SHA256 (RFC 5869), one to sign and one to seal -- so a key
    signing one cookie can never be read as one sealing another. *)

type t
(** A key derived from one secret. *)

val of_secret : string -> (t, string) result
(** [Error], in a sentence, for a secret shorter than 32 bytes: a secret is read
    at run time, and one too short to be a key is a deployment's mistake to say,
    not a program's to raise on. *)

type ring
(** The key that makes cookies, and the retired ones that still read them. *)

val ring : t -> t list -> ring
(** [ring newest retired]: every cookie is signed or sealed with [newest], and
    read with any of them, so a key is rotated by putting a new one first and
    the old one after it, and retired by leaving it out once every cookie it
    made has aged past its [max_age]. *)

(** {1 Signing and sealing}

    What a signed and an encrypted cookie are made of, for anything else that
    must come back as it was sent -- a link's token, a value in a URL. *)

val sign : ring -> string -> string
(** An HMAC-SHA256 of the text with the newest key: 32 bytes. *)

val verify : ring -> mac:string -> string -> bool
(** Whether [mac] is {!sign}'s of the text under any key of the ring, compared
    in constant time. *)

val seal : ring -> adata:string -> string -> string
(** The text encrypted with the newest key by AES-256-GCM, under a nonce of 96
    random bits from the operating system's generator, the nonce first and the
    tag last. [adata] is bound to it unencrypted: sealed under one, it opens
    under no other, which is how a cookie's value cannot be moved to another
    cookie. *)

val unseal : ring -> adata:string -> string -> string option
(** What {!seal} sealed under any key of the ring and this [adata]; [None] for
    anything else. *)
