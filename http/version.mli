(** The HTTP/1 versions a message is spoken in: what a request says it speaks
    ([Spindle.Request.version]), and what a test asks to be called with. *)

type t = Http_1_0 | Http_1_1
