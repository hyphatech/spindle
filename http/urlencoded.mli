(** [application/x-www-form-urlencoded], as the WHATWG URL standard reads and
    writes it: what a browser posts from a form with no file in it.

    {[
    Urlencoded.parse "name=Kim+Lee&tag=a&tag=b%26c"
    = [ ("name", "Kim Lee"); ("tag", "a"); ("tag", "b&c") ]
    ]}

    Every name and value is bytes as sent, percent-decoded: whether they are
    UTF-8 is the reader's to say, at the field. *)

val parse : string -> (string * string) list
(** Each field in order, a repeated name as often as it came: split at [&], then
    at the first [=], [+] read as a space and each [%XX] as its byte. An empty
    piece is passed over, a piece with no [=] is a name with an empty value, and
    a [%] not followed by two hex digits is itself. *)

val to_string : (string * string) list -> string
(** The fields as a browser writes them: a space as [+], and every byte but
    ASCII letters, digits and [*-._] as [%XX]. {!parse} reads it back as itself.
*)
