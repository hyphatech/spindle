(** [Cache-Control], as RFC 9111 §5.2 writes it: directives, each with an
    argument or none.

    {[
    Cache_control.parse {|max-age=60, private="Set-Cookie"|}
    = Ok [ ("max-age", Some "60"); ("private", Some "Set-Cookie") ]
    ]}

    A value to read and write: what a directive asks of a cache is the
    application's, and nothing here caches. *)

type t = (string * string option) list
(** Each directive in order, its name lower-cased, as it is compared, and its
    argument as it came, a quoted string's escapes undone. *)

val parse : string -> (t, string) result

val to_string : t -> (string, string) result
(** Each directive, its argument a quoted string where it is no token, or
    [Error] for what {!parse} would not read back as itself: a name that is no
    token or is not lower-cased, an argument no quoted string can hold. *)

val delta_seconds : t -> string -> int option
(** The first [name]'s argument as delta-seconds, where it is digits, quoted or
    not -- a recipient accepts either (RFC 9111 §5.2) -- and past what 31 bits
    hold, [2147483648], as §1.2.2 has a recipient read it. *)
