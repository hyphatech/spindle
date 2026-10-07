(* A path as the framework reads it: its segments and each parameter's
   codec. *)

(* [rest] takes every remaining segment. Its codec reads them as the matcher
   hands them over, each encoded again and joined by "/", so a segment
   holding an encoded "/" stays one segment. *)
type 'a spec = {
  name : string;
  codec : 'a Codec.t;
  or_not_found : bool;
  rest : bool;
}

type part = Fixed of string | Variable : 'a spec -> part

(* The kind keeps a joined path out of [Spindle.param]. *)
type ('a, 'kind) t =
  | Param : 'a spec -> ('a, [ `Param ]) t
  | Path : part list -> (unit, [ `Path ]) t

let parts_of : type a k. (a, k) t -> part list = function
  | Param p -> [ Variable p ]
  | Path l -> l

(* As the matcher reads it: a parameter is asked only whether it parses. *)
type segment =
  | Literal of string
  | Parameter of {
      name : string;
      or_not_found : bool;
      parses : string -> bool;
      shape : Codec.shape;
      kind : string option;
    }
  | Rest of string

let segments p =
  List.map
    (function
      | Fixed l -> Literal l
      | Variable p when p.rest -> Rest p.name
      | Variable p ->
          Parameter
            {
              name = p.name;
              or_not_found = p.or_not_found;
              parses = (fun s -> Option.is_some (Codec.parse p.codec s));
              shape = Codec.shape p.codec;
              kind = Codec.kind p.codec;
            })
    (parts_of p)

(* All but RFC 3986's unreserved characters, so any text is one segment. *)
let encode s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~') as c ->
          Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

(* What the matcher hands a rest parameter. *)
let join_rest segments = String.concat "/" (List.map encode segments)

let rest_codec =
  Codec.custom ~kind:"path" ~expects:"a path"
    ~parse:(function
      | "" -> Some []
      | s -> Some (List.map Uri.pct_decode (String.split_on_char '/' s)))
    ~print:join_rest ()
