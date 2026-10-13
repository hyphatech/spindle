(** A key as the framework holds it: {!Key}'s, and the two more a signed and an
    encrypted cookie are made with, which nothing outside the framework can use.
*)

type t
type ring

val of_secret : string -> (t, string) result
val ring : t -> t list -> ring

(** {1 For the application} *)

val sign : ring -> string -> string
val verify : ring -> mac:string -> string -> bool
val seal : ring -> adata:string -> string -> string
val unseal : ring -> adata:string -> string -> string option

(** {1 For a cookie}

    As above, under keys of their own: no text the application signs or seals is
    ever a cookie. *)

val sign_cookie : ring -> string -> string
val verify_cookie : ring -> mac:string -> string -> bool
val seal_cookie : ring -> adata:string -> string -> string
val unseal_cookie : ring -> adata:string -> string -> string option
