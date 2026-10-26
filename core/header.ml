let optional name description = Input.optional Input.header name description

let joined name description =
  Input.optional ~joined:true Input.header name description

let required name description = Input.required Input.header name description

let default name description value =
  Input.default Input.header name description value

(* HTTP's own values, each read by spindle_http's parser: a kind over the
   text, so it is described and refused as any other. *)
let http ~kind ~expects parse print =
  Wiretype.kind ~kind
    ~parse:(fun s ->
      Result.map_error (fun _ -> "This is not " ^ expects ^ ".") (parse s))
    ~print Wiretype.string

(* A value no field can hold prints as empty: a kind's printer answers a
   string. *)
let or_empty f v = Result.value (f v) ~default:""

let media_type =
  http ~kind:"media type" ~expects:"a media type" Spindle_http.Media_type.parse
    (or_empty Spindle_http.Media_type.to_string)

let credentials =
  http ~kind:"credentials" ~expects:"credentials" Spindle_http.Auth.credentials
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
  http ~kind:"media ranges" ~expects:"an Accept value"
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
  http ~kind:"weighted tokens" ~expects:"a list of weighted tokens"
    Spindle_http.Accept.parse_weighted (fun tokens ->
      String.concat ", " (List.map (fun (t, w) -> with_weight t w) tokens))

let cache_control =
  http ~kind:"directives" ~expects:"a Cache-Control value"
    Spindle_http.Cache_control.parse
    (or_empty Spindle_http.Cache_control.to_string)

let forwarded =
  http ~kind:"forwarded elements" ~expects:"a Forwarded value"
    Spindle_http.Forwarded.parse
    (or_empty Spindle_http.Forwarded.to_string)

let structured_item =
  http ~kind:"structured item" ~expects:"a structured item"
    Spindle_http.Structured.item
    (or_empty Spindle_http.Structured.item_to_string)

let structured_list =
  http ~kind:"structured list" ~expects:"a structured list"
    Spindle_http.Structured.list
    (or_empty Spindle_http.Structured.list_to_string)

let structured_dictionary =
  http ~kind:"structured dictionary" ~expects:"a structured dictionary"
    Spindle_http.Structured.dictionary
    (or_empty Spindle_http.Structured.dictionary_to_string)
