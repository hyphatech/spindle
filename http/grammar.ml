(* Written as RFC 9110's ABNF is, so a rule here reads beside its section. *)

module A = Angstrom

let is_tchar = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9'
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_' | '`'
  | '|' | '~' ->
      true
  | _ -> false

let ows = A.skip_while (function ' ' | '\t' -> true | _ -> false)
let token = A.take_while1 is_tchar

(* qdtext = HTAB / SP / %x21 / %x23-5B / %x5D-7E / obs-text *)
let is_qdtext = function
  | '\t' | ' ' | '!' | '\x23' .. '\x5b' | '\x5d' .. '\x7e' | '\x80' .. '\xff' ->
      true
  | _ -> false

(* quoted-pair = a backslash, then HTAB / SP / VCHAR / obs-text *)
let is_quotable = function
  | '\t' | ' ' | '\x21' .. '\x7e' | '\x80' .. '\xff' -> true
  | _ -> false

let quoted_string =
  A.(
    char '"'
    *> many
         (take_while1 is_qdtext
         <|> (char '\\' *> satisfy is_quotable >>| String.make 1))
    <* char '"' >>| String.concat "")

let value = A.(token <|> quoted_string)

let parameters =
  A.(
    many
      (ows *> char ';' *> ows
      *> option None
           (let+ name = token and+ _ = char '=' and+ v = value in
            Some (String.lowercase_ascii name, v)))
    >>| List.filter_map Fun.id)

let has_repeated_name pairs =
  let rec from seen = function
    | [] -> false
    | (name, _) :: rest -> List.mem name seen || from (name :: seen) rest
  in
  from [] pairs

let once p =
  A.(
    p >>= fun pairs ->
    if has_repeated_name pairs then fail "a parameter given twice"
    else return pairs)

let list_of element =
  A.(
    sep_by (ows *> char ',' <* ows) (option None (element >>| Option.some))
    >>| List.filter_map Fun.id)

let parse ~what p s =
  match A.parse_string ~consume:A.Consume.All A.(ows *> p <* ows) s with
  | Ok v -> Ok v
  | Error _ -> Error ("not " ^ what)
