type t =
  | Null
  | Bool of bool
  | Int of int
  | String of string
  | List of t list
  | Obj of (string * t) list
  | Raw of string

(* A number is spelled as wiretype spells it. *)
let rec of_value : Wiretype.Value.t -> t = function
  | Wiretype.Value.Null -> Null
  | Wiretype.Value.Bool b -> Bool b
  | Wiretype.Value.Number n -> Raw (Wiretype.Value.to_string (Number n))
  | Wiretype.Value.String s -> String s
  | Wiretype.Value.Array items -> List (List.map of_value items)
  | Wiretype.Value.Object members ->
      Obj (List.map (fun (name, v) -> (name, of_value v)) members)

let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let to_string v =
  let b = Buffer.create 4096 in
  let rec add_value indent = function
    | Null -> Buffer.add_string b "null"
    | Bool v -> Buffer.add_string b (string_of_bool v)
    | Int n -> Buffer.add_string b (string_of_int n)
    | String s -> Buffer.add_string b (json_string s)
    | Raw s -> Buffer.add_string b s
    | List [] -> Buffer.add_string b "[]"
    | Obj [] -> Buffer.add_string b "{}"
    | List items ->
        Buffer.add_string b "[";
        List.iteri
          (fun i item ->
            if i > 0 then Buffer.add_char b ',';
            Buffer.add_char b '\n';
            Buffer.add_string b (String.make (indent + 2) ' ');
            add_value (indent + 2) item)
          items;
        Buffer.add_char b '\n';
        Buffer.add_string b (String.make indent ' ');
        Buffer.add_string b "]"
    | Obj members ->
        Buffer.add_string b "{";
        List.iteri
          (fun i (k, item) ->
            if i > 0 then Buffer.add_char b ',';
            Buffer.add_char b '\n';
            Buffer.add_string b (String.make (indent + 2) ' ');
            Buffer.add_string b (json_string k);
            Buffer.add_string b ": ";
            add_value (indent + 2) item)
          members;
        Buffer.add_char b '\n';
        Buffer.add_string b (String.make indent ' ');
        Buffer.add_string b "}"
  in
  add_value 0 v;
  Buffer.add_char b '\n';
  Buffer.contents b
