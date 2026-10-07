type shape = String | Integer | Boolean | Enum of string list

type 'a t = {
  parse : string -> 'a option;
  print : 'a -> string;
  expects : string;
  shape : shape;
  kind : string option;
}

let string =
  {
    parse = Option.some;
    print = Fun.id;
    expects = "some text";
    shape = String;
    kind = None;
  }

let is_digit c = c >= '0' && c <= '9'

(* [int_of_string] also reads "0x1f", "1_000" and "+3", none of which a
   client means. *)
let parse_decimal of_string s =
  let digits =
    if String.starts_with ~prefix:"-" s then String.sub s 1 (String.length s - 1)
    else s
  in
  if String.length digits > 0 && String.for_all is_digit digits then of_string s
  else None

let int =
  {
    parse = parse_decimal int_of_string_opt;
    print = string_of_int;
    expects = "a whole number";
    shape = Integer;
    kind = None;
  }

let int64 =
  {
    parse = parse_decimal Int64.of_string_opt;
    print = Int64.to_string;
    expects = "a whole number";
    shape = Integer;
    kind = None;
  }

let bool =
  {
    parse = (function "true" -> Some true | "false" -> Some false | _ -> None);
    print = string_of_bool;
    expects = "true or false";
    shape = Boolean;
    kind = None;
  }

let enum ~kind to_string values =
  let words = List.map to_string values in
  {
    parse =
      (fun s -> List.find_opt (fun v -> String.equal (to_string v) s) values);
    print = to_string;
    expects = "one of " ^ String.concat ", " words;
    shape = Enum words;
    kind = Some kind;
  }

let custom ~kind ?expects ~parse ~print () =
  {
    parse;
    print;
    (* "a valid int64" reads as a sentence; "a int64" does not. *)
    expects = Option.value expects ~default:("a valid " ^ kind);
    shape = String;
    kind = Some kind;
  }

let parse c s = c.parse s
let print c v = c.print v
let expects c = c.expects
let shape c = c.shape
let kind c = c.kind

(* Parsed by spindle_http, never by the application. *)
let structured ~kind ~expects parse print =
  {
    parse = (fun s -> Result.to_option (parse s));
    print;
    expects;
    shape = String;
    kind = Some kind;
  }

(* A value no field can hold prints as empty: a codec's printer answers a
   string. *)
let or_empty f v = Result.value (f v) ~default:""

let media_type =
  structured ~kind:"media type" ~expects:"a media type"
    Spindle_http.Media_type.parse
    (or_empty Spindle_http.Media_type.to_string)

let credentials =
  structured ~kind:"credentials" ~expects:"credentials"
    Spindle_http.Auth.credentials
    (or_empty Spindle_http.Auth.to_string)

let qvalue_to_string w =
  if w >= 1000 then "1"
  else if w <= 0 then "0"
  else
    let digits = Printf.sprintf "%03d" w in
    let rec trimmed n =
      if n > 1 && Char.equal digits.[n - 1] '0' then trimmed (n - 1) else n
    in
    "0." ^ String.sub digits 0 (trimmed 3)

let with_weight text w =
  if w >= 1000 then text else text ^ ";q=" ^ qvalue_to_string w

let accept =
  structured ~kind:"media ranges" ~expects:"an Accept value"
    Spindle_http.Accept.parse_media (fun ranges ->
      String.concat ", "
        (List.map
           (fun (r : Spindle_http.Accept.range) ->
             with_weight
               (or_empty Spindle_http.Media_type.to_string
                  {
                    type_ = r.type_;
                    subtype = r.subtype;
                    parameters = r.parameters;
                  })
               r.weight)
           ranges))

let weighted =
  structured ~kind:"weighted tokens" ~expects:"a list of weighted tokens"
    Spindle_http.Accept.parse_weighted (fun tokens ->
      String.concat ", " (List.map (fun (t, w) -> with_weight t w) tokens))

let cache_control =
  structured ~kind:"directives" ~expects:"a Cache-Control value"
    Spindle_http.Cache_control.parse
    (or_empty Spindle_http.Cache_control.to_string)

let forwarded =
  structured ~kind:"forwarded elements" ~expects:"a Forwarded value"
    Spindle_http.Forwarded.parse
    (or_empty Spindle_http.Forwarded.to_string)

let structured_item =
  structured ~kind:"structured item" ~expects:"a structured item"
    Spindle_http.Structured.item
    (or_empty Spindle_http.Structured.item_to_string)

let structured_list =
  structured ~kind:"structured list" ~expects:"a structured list"
    Spindle_http.Structured.list
    (or_empty Spindle_http.Structured.list_to_string)

let structured_dictionary =
  structured ~kind:"structured dictionary" ~expects:"a structured dictionary"
    Spindle_http.Structured.dictionary
    (or_empty Spindle_http.Structured.dictionary_to_string)
