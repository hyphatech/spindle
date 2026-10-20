module M = Spindle_http.Multipart

type t = Refusal.t M.t

type part = M.part = {
  name : string;
  filename : string option;
  content_type : Spindle_http.Media_type.t;
  headers : (string * string) list;
}

(* What the route answers: the body's own failure already is a refusal. *)
let refusal = function
  | M.Malformed detail -> Body_repr.not_multipart ~detail
  | M.Head_too_large -> Refusal.too_large
  | M.Source r -> r

let next t = Result.map_error refusal (M.next t)
let read t = Result.map_error refusal (M.read t)
