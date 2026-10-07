module A = Angstrom
module G = Grammar

type spec = From of int | Span of int * int | Suffix of int
type t = Bytes of spec list | Other of string

(* 1*DIGIT, as [max_int] when longer than an int holds: past the end of
   anything. *)
let position =
  A.(
    take_while1 (function '0' .. '9' -> true | _ -> false) >>| fun digits ->
    match int_of_string_opt digits with Some n -> n | None -> max_int)

(* suffix-range = "-" suffix-length *)
let suffix = A.(char '-' *> position >>| fun n -> Suffix n)

(* int-range = first-pos "-" [ last-pos ] *)
let int_range =
  A.(
    let* first = position <* char '-' in
    option None (position >>| Option.some) >>= function
    | None -> return (From first)
    | Some last when last >= first -> return (Span (first, last))
    | Some _ -> fail "a range that ends before it starts")

let spec = A.(suffix <|> int_range)

(* ranges-specifier = range-unit "=" range-set; ranges of another unit are
   not read. *)
let specifier =
  A.(
    G.token <* char '=' >>= fun unit ->
    match String.lowercase_ascii unit with
    | "bytes" -> (
        G.list_of spec >>= function
        | [] -> fail "no range"
        | specs -> return (Bytes specs))
    | other -> take_while (fun _ -> true) *> return (Other other))

let parse = G.parse ~what:"a Range value" specifier

let satisfy ~length = function
  | From first when first < length -> Some (first, length - 1)
  | Span (first, last) when first < length -> Some (first, min last (length - 1))
  | Suffix n when n > 0 && length > 0 -> Some (max 0 (length - n), length - 1)
  | From _ | Span _ | Suffix _ -> None

let content_range ~first ~last ~length =
  Printf.sprintf "bytes %d-%d/%d" first last length

let content_range_unsatisfied ~length = Printf.sprintf "bytes */%d" length
