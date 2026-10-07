module A = Angstrom
module G = Grammar

type t = { weak : bool; opaque : string }
type condition = Any | Tags of t list

let is_etagc = function
  | '\x21' | '\x23' .. '\x7e' | '\x80' .. '\xff' -> true
  | _ -> false

(* entity-tag = [ weak ] opaque-tag; [W/] is case-sensitive, so [w/"x"] is
   no entity tag. *)
let entity_tag =
  A.(
    let+ weak = option false (string "W/" *> return true)
    and+ opaque = char '"' *> take_while is_etagc <* char '"' in
    { weak; opaque })

let parse = G.parse ~what:"an entity tag" entity_tag

let condition =
  G.parse ~what:"a list of entity tags"
    A.(char '*' *> return Any <|> (G.list_of entity_tag >>| fun l -> Tags l))

let to_string t =
  if String.for_all is_etagc t.opaque then
    Ok ((if t.weak then "W/\"" else "\"") ^ t.opaque ^ "\"")
  else Error "an opaque tag with a quote, a space or a control character"

let strong_equal a b =
  (not a.weak) && (not b.weak) && String.equal a.opaque b.opaque

let weak_equal a b = String.equal a.opaque b.opaque
