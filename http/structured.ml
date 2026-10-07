(* Each parser is RFC 9651 §4.2's algorithm of the same name, step for step,
   and each printer §4.1's: the published tests are run against them whole. *)

module A = Angstrom

type bare =
  | Integer of int
  | Decimal of int
  | String of string
  | Token of string
  | Bytes of string
  | Boolean of bool
  | Date of int
  | Display of string

type parameters = (string * bare) list
type item = bare * parameters
type member = Item of item | Inner of item list * parameters
type dictionary = (string * member) list

let ( let* ) = Result.bind
let is_digit = function '0' .. '9' -> true | _ -> false
let is_lcalpha = function 'a' .. 'z' -> true | _ -> false
let is_alpha = function 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false
let sp = A.skip_many (A.char ' ')
let ows = A.skip_while (function ' ' | '\t' -> true | _ -> false)

(* A key given twice keeps its first place and takes its last value. *)
let last_value_wins pairs =
  let last = Hashtbl.create (List.length pairs) in
  List.iter (fun (k, v) -> Hashtbl.replace last k v) pairs;
  List.filter_map
    (fun (k, _) ->
      match Hashtbl.find_opt last k with
      | Some v ->
          Hashtbl.remove last k;
          Some (k, v)
      | None -> None)
    pairs

(* ------------------------------------------------------------------ *)
(* Parsing, §4.2 *)

(* §4.2.4: an integer of fifteen digits at most, or a decimal of twelve
   before its point and one to three after it. *)
let number =
  A.(
    let* negative = option false (char '-' *> return true) in
    let* whole = take_while1 is_digit in
    let* fraction =
      option None (char '.' *> take_while is_digit >>| Option.some)
    in
    let sign n = if negative then -n else n in
    match fraction with
    | None when String.length whole <= 15 -> (
        match int_of_string_opt whole with
        | Some n -> return (Integer (sign n))
        | None -> fail "an integer")
    | None -> fail "an integer of fifteen digits at most"
    | Some f
      when String.length whole <= 12
           && String.length f >= 1
           && String.length f <= 3 -> (
        match
          ( int_of_string_opt whole,
            int_of_string_opt (f ^ String.make (3 - String.length f) '0') )
        with
        | Some w, Some t -> return (Decimal (sign ((w * 1000) + t)))
        | _ -> fail "a decimal")
    | Some _ -> fail "a decimal of twelve digits and three after its point")

(* §4.2.5 *)
let sf_string =
  A.(
    char '"'
    *> many
         (take_while1 (fun c -> c >= ' ' && c <= '~' && c <> '"' && c <> '\\')
         <|> (char '\\' *> satisfy (fun c -> c = '"' || c = '\\')
             >>| String.make 1))
    <* char '"'
    >>| fun parts -> String (String.concat "" parts))

(* §4.2.6 *)
let token =
  A.(
    let+ first = satisfy (fun c -> is_alpha c || c = '*')
    and+ rest =
      take_while (fun c -> Grammar.is_tchar c || c = ':' || c = '/')
    in
    Token (String.make 1 first ^ rest))

(* §4.2.7: padding and pad bits read as they are, since the RFC has a
   parser not fail for either. *)
let bytes =
  A.(
    char ':'
    *> take_while (function
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '+' | '/' | '=' -> true
      | _ -> false)
    <* char ':'
    >>= fun encoded ->
    match Base64.decode ~pad:false encoded with
    | Ok b -> return (Bytes b)
    | Error _ -> fail "base64")

(* §4.2.8 *)
let boolean =
  A.(
    char '?' *> (char '1' *> return true <|> char '0' *> return false)
    >>| fun b -> Boolean b)

(* §4.2.9 *)
let date =
  A.(
    char '@' *> number >>= function
    | Integer n -> return (Date n)
    | _ -> fail "a date")

(* One lower-case hex digit, as §4.2.10 has a display string encoded. *)
let hex =
  A.(
    satisfy (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
    >>| function
    | '0' .. '9' as c -> Char.code c - Char.code '0'
    | c -> Char.code c - Char.code 'a' + 10)

(* §4.2.10: printable ASCII, each byte past it percent-encoded in lower
   case, and the whole UTF-8. *)
let display =
  A.(
    string "%\""
    *> many
         (take_while1 (fun c -> c >= ' ' && c <= '~' && c <> '%' && c <> '"')
         <|> char '%'
             *> let+ hi = hex and+ lo = hex in
                String.make 1 (Char.chr ((hi * 16) + lo)))
    <* char '"'
    >>= fun parts ->
    let s = String.concat "" parts in
    if String.is_valid_utf_8 s then return (Display s) else fail "UTF-8")

(* §4.2.3.1 *)
let bare =
  A.(
    peek_char_fail >>= function
    | '-' | '0' .. '9' -> number
    | '"' -> sf_string
    | 'a' .. 'z' | 'A' .. 'Z' | '*' -> token
    | ':' -> bytes
    | '?' -> boolean
    | '@' -> date
    | '%' -> display
    | _ -> fail "a bare item")

(* §4.2.3.3 *)
let key =
  A.(
    let+ first = satisfy (fun c -> is_lcalpha c || c = '*')
    and+ rest =
      take_while (fun c ->
          is_lcalpha c || is_digit c || c = '_' || c = '-' || c = '.' || c = '*')
    in
    String.make 1 first ^ rest)

(* §4.2.3.2 *)
let parameters =
  A.(
    many
      (char ';' *> sp
      *> let+ k = key and+ v = option (Boolean true) (char '=' *> bare) in
         (k, v))
    >>| last_value_wins)

let item_ = A.both bare parameters

(* §4.2.1.2: items apart by spaces, and nothing else between them. *)
let inner =
  A.(
    char '('
    *> fix (fun items ->
        sp
        *> (char ')' *> return []
           <|> let* i = item_ in
               peek_char_fail >>= function
               | ' ' | ')' -> items >>| fun rest -> i :: rest
               | _ -> fail "an inner list"))
    >>= fun items ->
    parameters >>| fun ps -> Inner (items, ps))

let member =
  A.(
    peek_char_fail >>= function '(' -> inner | _ -> item_ >>| fun i -> Item i)

(* §4.2.1 and §4.2.2: members apart by a comma, whitespace around it, and no
   comma after the last. *)
let members element =
  A.(
    option []
      (let+ first = element
       and+ rest = many (ows *> char ',' *> ows *> element) in
       first :: rest)
    <* ows)

let dictionary_member =
  A.(
    let+ k = key
    and+ m =
      char '=' *> member <|> (parameters >>| fun ps -> Item (Boolean true, ps))
    in
    (k, m))

(* §4.2: the field's value, spaces around it and nothing after it. *)
let parse ~what p s =
  match A.parse_string ~consume:A.Consume.All A.(sp *> p <* sp) s with
  | Ok v -> Ok v
  | Error _ -> Error ("not " ^ what)

let item = parse ~what:"a structured item" item_
let list = parse ~what:"a structured list" (members member)

let dictionary =
  parse ~what:"a structured dictionary"
    A.(members dictionary_member >>| last_value_wins)

(* ------------------------------------------------------------------ *)
(* Serialising, §4.1 *)

let max_integer = 999_999_999_999_999

let integer_to_string n =
  if n >= -max_integer && n <= max_integer then Ok (string_of_int n)
  else Error "an integer past fifteen digits"

(* §4.1.5, the thousandths already exact: the fraction without its
   trailing zeros, and one digit at least. *)
let decimal_to_string t =
  let a = abs t in
  (* Bounded before [abs] is trusted: [abs min_int] is negative. *)
  if t < -max_integer || t > max_integer then
    Error "a decimal past twelve digits"
  else
    let digits = Printf.sprintf "%03d" (a mod 1000) in
    let rec significant n =
      if n > 1 && Char.equal digits.[n - 1] '0' then significant (n - 1) else n
    in
    Ok
      ((if t < 0 then "-" else "")
      ^ string_of_int (a / 1000)
      ^ "."
      ^ String.sub digits 0 (significant 3))

let sf_string_to_string s =
  if String.for_all (fun c -> c >= ' ' && c <= '~') s then (
    let b = Buffer.create (String.length s + 2) in
    Buffer.add_char b '"';
    String.iter
      (fun c ->
        if c = '"' || c = '\\' then Buffer.add_char b '\\';
        Buffer.add_char b c)
      s;
    Buffer.add_char b '"';
    Ok (Buffer.contents b))
  else Error "a string outside printable ASCII"

let token_to_string t =
  if
    String.length t > 0
    && (is_alpha t.[0] || t.[0] = '*')
    && String.for_all (fun c -> Grammar.is_tchar c || c = ':' || c = '/') t
  then Ok t
  else Error "not a token"

let display_to_string s =
  if not (String.is_valid_utf_8 s) then
    Error "a display string that is not UTF-8"
  else
    let b = Buffer.create (String.length s + 3) in
    Buffer.add_string b "%\"";
    String.iter
      (fun c ->
        if c = '%' || c = '"' || c < ' ' || c > '~' then
          Buffer.add_string b (Printf.sprintf "%%%02x" (Char.code c))
        else Buffer.add_char b c)
      s;
    Buffer.add_char b '"';
    Ok (Buffer.contents b)

let bare_to_string = function
  | Integer n -> integer_to_string n
  | Decimal t -> decimal_to_string t
  | String s -> sf_string_to_string s
  | Token t -> token_to_string t
  | Bytes b -> Ok (":" ^ Base64.encode_string b ^ ":")
  | Boolean b -> Ok (if b then "?1" else "?0")
  | Date n -> Result.map (fun n -> "@" ^ n) (integer_to_string n)
  | Display s -> display_to_string s

let key_to_string k =
  if
    String.length k > 0
    && (is_lcalpha k.[0] || k.[0] = '*')
    && String.for_all
         (fun c ->
           is_lcalpha c || is_digit c || c = '_' || c = '-' || c = '.'
           || c = '*')
         k
  then Ok k
  else Error "not a key"

let map_result f xs =
  List.fold_left
    (fun acc x ->
      let* acc = acc in
      let* s = f x in
      Ok (s :: acc))
    (Ok []) xs
  |> Result.map List.rev

(* A reader keeps the last of two members of one key (§4.2), so a value
   written with two would not read back as itself. *)
let repeats_a_key pairs =
  let rec from seen = function
    | [] -> false
    | (k, _) :: rest -> List.mem k seen || from (k :: seen) rest
  in
  from [] pairs

let parameters_to_string ps =
  if repeats_a_key ps then Error "a parameter key given twice"
  else
    Result.map (String.concat "")
      (map_result
         (fun (k, v) ->
           let* k = key_to_string k in
           match v with
           | Boolean true -> Ok (";" ^ k)
           | v -> Result.map (fun v -> ";" ^ k ^ "=" ^ v) (bare_to_string v))
         ps)

let item_to_string (b, ps) =
  let* b = bare_to_string b in
  let* ps = parameters_to_string ps in
  Ok (b ^ ps)

let member_to_string = function
  | Item i -> item_to_string i
  | Inner (items, ps) ->
      let* items = map_result item_to_string items in
      let* ps = parameters_to_string ps in
      Ok ("(" ^ String.concat " " items ^ ")" ^ ps)

let list_to_string members =
  Result.map (String.concat ", ") (map_result member_to_string members)

let dictionary_to_string d =
  if repeats_a_key d then Error "a dictionary key given twice"
  else
    Result.map (String.concat ", ")
      (map_result
         (fun (k, m) ->
           let* k = key_to_string k in
           match m with
           | Item (Boolean true, ps) ->
               Result.map (fun ps -> k ^ ps) (parameters_to_string ps)
           | m -> Result.map (fun m -> k ^ "=" ^ m) (member_to_string m))
         d)
