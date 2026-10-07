module A = Angstrom
module G = Grammar

type value = Token68 of string | Params of (string * string) list
type t = { scheme : string; value : value }

(* token68 = 1*( ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" ) *"=" *)
let token68 =
  A.(
    let+ body =
      take_while1 (function
        | 'a' .. 'z'
        | 'A' .. 'Z'
        | '0' .. '9'
        | '-' | '.' | '_' | '~' | '+' | '/' ->
            true
        | _ -> false)
    and+ pad = take_while (Char.equal '=') in
    body ^ pad)

(* auth-param = token BWS "=" BWS ( token / quoted-string ) *)
let param =
  A.(
    let+ name = G.token and+ _ = G.ows *> char '=' <* G.ows and+ v = G.value in
    (String.lowercase_ascii name, v))

let spaces = A.skip_many1 (A.char ' ')

(* Parameters where the text parses as them, otherwise a token68: "abc==" is
   no parameter, having no value after its "=". *)
let after_scheme ~params =
  A.(
    option (Params []) (spaces *> (params <|> (token68 >>| fun t -> Token68 t))))

let scheme = A.(G.token >>| String.lowercase_ascii)

let credentials =
  G.parse ~what:"credentials"
    A.(
      let+ scheme = scheme
      and+ value =
        after_scheme
          ~params:
            ( G.once (G.list_of param) >>= function
              | [] -> fail "no parameter"
              | ps -> return (Params ps) )
      in
      { scheme; value })

(* Each element of a challenge list begins a challenge or adds a parameter
   to the one before it: a token followed by "=" is a parameter. *)
type element = Starts of t | Continues of (string * string)

let element =
  A.(
    param
    >>| (fun p -> Continues p)
    <|>
    let+ scheme = scheme
    and+ value = after_scheme ~params:(param >>| fun p -> Params [ p ]) in
    Starts { scheme; value })

(* A challenge's parameters are gathered last first and put in order once,
   each name at most once (RFC 9110 §11.2). *)
let challenges_of_elements elements =
  let in_order c =
    match c.value with
    | Params ps -> { c with value = Params (List.rev ps) }
    | Token68 _ -> c
  in
  let rec group acc = function
    | [] -> Ok (List.rev_map in_order acc)
    | Starts c :: rest -> group (c :: acc) rest
    | Continues p :: rest -> (
        match acc with
        | ({ value = Params ps; _ } as c) :: before
          when not (List.mem_assoc (fst p) ps) ->
            group ({ c with value = Params (p :: ps) } :: before) rest
        | { value = Params _ | Token68 _; _ } :: _ | [] ->
            Error "not challenges")
  in
  group [] elements

let challenges s =
  Result.bind
    (G.parse ~what:"challenges" (G.list_of element) s)
    challenges_of_elements

let equal a b =
  String.equal a.scheme b.scheme
  &&
  match (a.value, b.value) with
  | Token68 x, Token68 y -> String.equal x y
  | Params x, Params y ->
      List.equal (fun (n, v) (m, w) -> String.equal n m && String.equal v w) x y
  | Token68 _, Params _ | Params _, Token68 _ -> false

(* Read back rather than checked piece by piece, so what is written is
   exactly what the reader takes. The error names no part of the value,
   which is a secret. *)
let to_string t =
  let s =
    match t.value with
    | Token68 token -> t.scheme ^ " " ^ token
    | Params [] -> t.scheme
    | Params ps ->
        t.scheme ^ " "
        ^ String.concat ", "
            (List.map (fun (n, v) -> n ^ "=" ^ Field.quoted v) ps)
  in
  match credentials s with
  | Ok read when equal read t -> Ok s
  | Ok _ | Error _ -> Error "credentials their reader would not read back"
