module A = Angstrom
module G = Grammar

type name = Address of string | Unknown | Obfuscated of string
type port = Port of int | Obfuscated_port of string
type node = { name : name; port : port option }

type element = {
  for_ : node option;
  by : node option;
  host : string option;
  proto : string option;
  extensions : (string * string) list;
}

(* obfnode = "_" 1*( ALPHA / DIGIT / "." / "_" / "-" ), and obfport alike *)
let obfuscated_identifier =
  A.(
    let+ _ = char '_'
    and+ rest =
      take_while1 (function
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
        | _ -> false)
    in
    "_" ^ rest)

let address_if valid text =
  match valid text with
  | Ok _ -> A.return (Address text)
  | Error _ -> A.fail "an address"

(* nodename = IPv4address / "[" IPv6address "]" / "unknown" / obfnode *)
let nodename =
  A.(
    char '[' *> take_till (Char.equal ']')
    <* char ']'
    >>= address_if Ipaddr.V6.of_string
    <|> string_ci "unknown" *> return Unknown
    <|> (obfuscated_identifier >>| fun o -> Obfuscated o)
    <|> (take_while1 (function '0' .. '9' | '.' -> true | _ -> false)
        >>= address_if Ipaddr.V4.of_string))

(* node-port = port / obfport, a port being 1*5DIGIT *)
let port =
  A.(
    char ':'
    *> (take_while1 (function '0' .. '9' -> true | _ -> false)
       >>= (fun digits ->
       match int_of_string_opt digits with
       | Some n when String.length digits <= 5 && n <= 65535 -> return (Port n)
       | Some _ | None -> fail "a port")
       <|> (obfuscated_identifier >>| fun o -> Obfuscated_port o)))

let node =
  A.(
    let+ name = nodename and+ port = option None (port >>| Option.some) in
    { name; port })

let parse_whole p value =
  Result.to_option (A.parse_string ~consume:A.Consume.All p value)

(* RFC 3986 §3.1: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) *)
let scheme_of_string value =
  let is_alpha = function 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false in
  if
    String.length value > 0
    && is_alpha value.[0]
    && String.for_all
         (fun c ->
           is_alpha c
           || match c with '0' .. '9' | '+' | '-' | '.' -> true | _ -> false)
         value
  then Some (String.lowercase_ascii value)
  else None

let empty =
  { for_ = None; by = None; host = None; proto = None; extensions = [] }

(* Each parameter at most once per element (RFC 7239 §4). *)
let element_of_pairs pairs =
  let rec add seen e = function
    | [] -> Some { e with extensions = List.rev e.extensions }
    | (name, _) :: _ when List.mem name seen -> None
    | (name, value) :: rest -> (
        let next e = add (name :: seen) e rest in
        match name with
        | "for" ->
            Option.bind (parse_whole node value) (fun n ->
                next { e with for_ = Some n })
        | "by" ->
            Option.bind (parse_whole node value) (fun n ->
                next { e with by = Some n })
        | "host" -> next { e with host = Some value }
        | "proto" ->
            Option.bind (scheme_of_string value) (fun p ->
                next { e with proto = Some p })
        | _ -> next { e with extensions = (name, value) :: e.extensions })
  in
  add [] empty pairs

(* forwarded-element = [ forwarded-pair ] *( ";" [ forwarded-pair ] ), no
   whitespace within it *)
let element =
  A.(
    sep_by (char ';')
      (option None
         (let+ name = G.token and+ _ = char '=' and+ value = G.value in
          Some (String.lowercase_ascii name, value)))
    >>= fun pairs ->
    match element_of_pairs (List.filter_map Fun.id pairs) with
    | Some e -> return e
    | None -> fail "an element")

let parse = G.parse ~what:"a Forwarded value" (G.list_of element)

let node_to_string n =
  (match n.name with
    | Address a when String.contains a ':' -> "[" ^ a ^ "]"
    | Address a -> a
    | Unknown -> "unknown"
    | Obfuscated o -> o)
  ^
  match n.port with
  | None -> ""
  | Some (Port p) -> ":" ^ string_of_int p
  | Some (Obfuscated_port o) -> ":" ^ o

let written elements =
  let pair name value = name ^ "=" ^ Field.quoted value in
  String.concat ", "
    (List.map
       (fun e ->
         String.concat ";"
           (List.filter_map Fun.id
              [
                Option.map (fun n -> pair "for" (node_to_string n)) e.for_;
                Option.map (fun n -> pair "by" (node_to_string n)) e.by;
                Option.map (pair "host") e.host;
                Option.map (pair "proto") e.proto;
              ]
           @ List.map (fun (n, v) -> pair n v) e.extensions))
       elements)

let equal_name a b =
  match (a, b) with
  | Address x, Address y | Obfuscated x, Obfuscated y -> String.equal x y
  | Unknown, Unknown -> true
  | (Address _ | Obfuscated _ | Unknown), _ -> false

let equal_port a b =
  match (a, b) with
  | Port x, Port y -> x = y
  | Obfuscated_port x, Obfuscated_port y -> String.equal x y
  | (Port _ | Obfuscated_port _), _ -> false

let equal_node a b =
  equal_name a.name b.name && Option.equal equal_port a.port b.port

let equal_element a b =
  Option.equal equal_node a.for_ b.for_
  && Option.equal equal_node a.by b.by
  && Option.equal String.equal a.host b.host
  && Option.equal String.equal a.proto b.proto
  && List.equal
       (fun (n, v) (m, w) -> String.equal n m && String.equal v w)
       a.extensions b.extensions

(* Read back rather than checked piece by piece, so what is written is
   exactly what the reader takes: an extension named as a parameter of
   the element's own, or twice, a node or a scheme that is none. *)
let to_string elements =
  let s = written elements in
  match parse s with
  | Ok read when List.equal equal_element read elements -> Ok s
  | Ok _ | Error _ -> Error "elements their reader would not read back"
