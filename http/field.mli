(** The field grammar every message shares: RFC 9110's tokens, a field line
    split and checked, a list field's elements, and a field found by name.

    Both readers and the writer use this module and no grammar of their own, so
    what one of them refuses the others cannot let through. *)

val is_token : string -> bool
(** One or more of RFC 9110's [tchar]: what a method and a field name are. *)

val parse : string -> (string * string, string) result
(** A field line, its line ending already gone: a token name, a colon with no
    whitespace before it, and a value of visible characters, [obs-text], spaces
    and tabs, answered trimmed of the whitespace around it. [Error] says what
    was wrong -- a line beginning with whitespace (folded onto the one before
    it), no colon, a name that is not a token, a control character in the value
    -- in words for a log. *)

val is_text : string -> bool
(** Whether a string holds only what a field value may: visible characters,
    [obs-text], spaces and tabs -- which is what a reason phrase may hold too.
*)

val is_writable : string * string -> bool
(** Whether a field may be written: its name a token, its value what {!parse}
    reads -- no control character but tab. A CR, LF or NUL would let whoever
    chose the value end the field, or the whole head, where they liked, and any
    other is a value one reader stops at and another does not. *)

val find : (string * string) list -> string -> string option
(** The first value of the field named, whatever the case of either name. *)

val all : (string * string) list -> string -> string list
(** Every value of the field named, in the order they came. *)

val elements : string -> string list
(** A list field's elements, as RFC 9110 §5.6.1 writes them: split at the commas
    outside a quoted string and trimmed, with the empty ones left out. An
    element keeps its quotes; what is inside them is its structure's to read. *)

val quoted : string -> string
(** A parameter's or a directive's value as it is written: the value itself
    where it is a token, and otherwise a quoted string, a quote and a backslash
    escaped. A control character is left as it is, for {!is_writable} to refuse
    with the field. *)

val has_element : (string * string) list -> string -> string -> bool
(** [has_element fields name e]: whether any field named [name] lists [e],
    compared without regard to case -- [Connection: close] for [name]
    ["connection"] and [e] ["close"]. *)
