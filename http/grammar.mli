(** RFC 9110 §5.6's pieces, which field values are built from, as parsers: one
    token, one quoted string and one list of parameters, so every structure that
    holds them reads them the same way. *)

val is_tchar : char -> bool
val ows : unit Angstrom.t
val token : string Angstrom.t

val value : string Angstrom.t
(** A token or a quoted string: what a parameter holds. *)

val parameters : (string * string) list Angstrom.t
(** [*( OWS ";" OWS [ parameter ] )], each name lower-cased, as RFC 9110 §5.6.6
    has names compared. *)

val once : (string * 'a) list Angstrom.t -> (string * 'a) list Angstrom.t
(** The parameters [p] reads, failing where a name is given twice: RFC 6838 §4.3
    and RFC 9110 §11.2 have each name once, and which of two a reader takes is
    how two readers come to disagree about one value. *)

val list_of : 'a Angstrom.t -> 'a list Angstrom.t
(** RFC 9110 §5.6.1's [#element]: elements between commas, the empty ones a
    recipient accepts left out. *)

val parse : what:string -> 'a Angstrom.t -> string -> ('a, string) result
(** The whole value, and whitespace around it, as [p]; [Error] says it is not
    [what] and quotes nothing of the value, which may be a credential. *)
