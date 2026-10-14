module A = Angstrom
module G = Grammar

type t = {
  type_ : string;
  subtype : string;
  parameters : (string * string) list;
}

(* No whitespace around the slash: RFC 9110 §8.3.1 has none. *)
let parser =
  A.(
    let+ type_ = G.token
    and+ _ = char '/'
    and+ subtype = G.token
    and+ parameters = G.once G.parameters in
    {
      type_ = String.lowercase_ascii type_;
      subtype = String.lowercase_ascii subtype;
      parameters;
    })

let parse = G.parse ~what:"a media type" parser

let equal a b =
  String.equal a.type_ b.type_
  && String.equal a.subtype b.subtype
  && List.equal
       (fun (n, v) (m, w) -> String.equal n m && String.equal v w)
       a.parameters b.parameters

(* Read back rather than checked piece by piece, so what is written is
   exactly what the reader takes: a name that is no token, or not
   lower-cased, a parameter twice, a value no quoted string holds. *)
let to_string t =
  let s =
    String.concat ""
      ((t.type_ ^ "/" ^ t.subtype)
      :: List.map (fun (n, v) -> "; " ^ n ^ "=" ^ Field.quoted v) t.parameters)
  in
  match parse s with
  | Ok read when equal read t -> Ok s
  | Ok _ | Error _ -> Error "a media type its reader would not read back"

(* A wildcard is a whole type or subtype, or a suffix's: anything else
   with a star in it would be compared as it is spelt. *)
let is_pattern p =
  let starless s = Field.is_token s && not (String.contains s '*') in
  match String.split_on_char '/' p with
  | [ ty; sub ] ->
      starless ty
      && (String.equal sub "*"
         || String.starts_with ~prefix:"*+" sub
            && starless (String.sub sub 2 (String.length sub - 2))
         || starless sub)
  | _ -> false

let matches pattern (t : t) =
  match String.split_on_char '/' (String.lowercase_ascii pattern) with
  | [ ty; "*" ] -> String.equal ty t.type_
  | [ ty; sub ] when String.starts_with ~prefix:"*+" sub ->
      String.equal ty t.type_
      && String.ends_with
           ~suffix:(String.sub sub 1 (String.length sub - 1))
           t.subtype
  | [ ty; sub ] -> String.equal ty t.type_ && String.equal sub t.subtype
  | _ -> false

let parameter t name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (n, v) -> if String.equal n name then Some v else None)
    t.parameters
