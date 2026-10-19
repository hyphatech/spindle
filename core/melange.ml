module D = Described
module S = Wiretype.Schema

(* What a route takes, each by the label its function names it with. *)
type input = {
  label : string;
  name : string;  (** as the request carries it *)
  located : D.located;
  required : bool;
  component : string;
}

type sends =
  | No_body
  | Json of { component : string; required : bool }
  | Form of { component : string; files : Dep.file list }
  | Raw of string

(* What a stream's event or a socket's message carries: JSON of a
   component, text, or bytes. *)
type carries = Json_of of string | Text_of | Bytes_of

type answer =
  | Value of int list * string
  | Empty of int list
  | Text
  | Stream of (string * carries) list  (** each event's name and data *)
  | Socket of {
      subprotocol : string option;
      client : carries;
      server : carries;
    }

type plan = {
  route : D.route;
  inputs : input list;
  sends : sends;
  answer : answer;
}

let route_name (r : D.route) =
  Spindle_http.Meth.to_string r.info.meth ^ " " ^ r.info.pattern

(* The routes a function can call: the rest answer a response of any kind,
   read parts no description names, or open a socket with a header, which a
   browser's WebSocket cannot send. *)
let callable (r : D.route) =
  (match r.returns with
    | D.Value _ | D.Empty _ | D.Html | D.Text | D.Events _ -> true
    | D.Socket _ ->
        not
          (List.exists
             (fun (p : D.parameter) ->
               match p.located with
               | D.In_header -> true
               | D.In_path | D.In_query | D.In_cookie -> false)
             r.parameters)
    | D.Response -> false)
  &&
  match r.body with
  | Some D.Parts_body -> false
  | Some (D.Json_body _ | D.Form_body _ | D.Raw_body _) | None -> true

(* A schema the route reads or answers is a component of its own, named for
   the route, unless it is one already. *)
let plan_of own (r : D.route) =
  let component suffix = function
    | S.Ref name -> name
    | schema ->
        let name = S.name_of_kind (r.operation_id ^ " " ^ suffix) in
        own := (name, schema) :: !own;
        name
  in
  let carries suffix = function
    | D.Json_data schema -> Json_of (component suffix schema)
    | D.Text_data -> Text_of
    | D.Binary_data -> Bytes_of
  in
  let inputs =
    List.filter_map
      (fun (p : D.parameter) ->
        match p.located with
        | D.In_cookie -> None
        | D.In_path | D.In_query | D.In_header ->
            Some
              {
                label = S.Melange.name p.name;
                name = p.name;
                located = p.located;
                required = p.required;
                component = component p.name p.schema;
              })
      r.parameters
  in
  let sends =
    match r.body with
    | None | Some D.Parts_body -> No_body
    | Some (D.Json_body { schema; required; _ }) ->
        Json { component = component "body" schema; required }
    | Some (D.Form_body { fields; files }) ->
        Form { component = component "body" fields; files }
    | Some (D.Raw_body content_types) ->
        Raw
          (match content_types with
          | t :: _ -> t
          | [] -> "application/octet-stream")
  in
  let answer =
    match r.returns with
    | D.Value { statuses; schema; _ } ->
        Value (List.map fst statuses, component "answer" schema)
    | D.Empty statuses -> Empty (List.map fst statuses)
    | D.Events events ->
        Stream
          (List.map
             (fun (name, data) -> (name, carries (name ^ " data") data))
             events)
    | D.Socket { subprotocol; client; server } ->
        Socket
          {
            subprotocol;
            client = carries "client" client;
            server = carries "server" server;
          }
    | D.Html | D.Text | D.Response -> Text
  in
  { route = r; inputs; sends; answer }

let labels p =
  ("origin" :: List.map (fun i -> i.label) p.inputs)
  @ (match p.sends with
    | Json _ | Raw _ -> [ "body" ]
    | Form { files; _ } ->
        "body" :: List.map (fun (f : Dep.file) -> S.Melange.name f.name) files
    | No_body -> [])
  @
  match p.answer with
  | Stream _ -> [ "on_event" ]
  | Socket _ -> [ "on_message" ]
  | Value _ | Empty _ | Text -> []

(* A stream's events as a variant: its type, named for the route, and a
   constructor per event. *)
let event_type p = p.route.operation_id ^ "_event"
let constructor name = String.capitalize_ascii (S.Melange.name name)

let rec repeated = function
  | [] -> []
  | x :: rest -> (if List.mem x rest then [ x ] else []) @ repeated rest

(* What a printed client could not say: a name taken twice. *)
let clashes components plans =
  let lowered = List.map (fun (n, _) -> S.Melange.name n) components in
  let values =
    List.concat_map
      (fun n ->
        [
          "read_" ^ n;
          "write_" ^ n;
          "decode_" ^ n;
          n ^ "_of_json";
          "encode_" ^ n;
          n ^ "_to_json";
        ])
      lowered
  in
  List.map
    (fun n -> Printf.sprintf "two components are both %s in OCaml" n)
    (List.sort_uniq String.compare (repeated lowered))
  @ List.filter_map
      (fun p ->
        if List.mem p.route.operation_id values then
          Some
            (Printf.sprintf "%s is the operation %s, a name the module has"
               (route_name p.route) p.route.operation_id)
        else None)
      plans
  @ List.concat_map
      (fun p ->
        List.map
          (fun l ->
            Printf.sprintf "%s takes two inputs labelled %s"
              (route_name p.route) l)
          (List.sort_uniq String.compare (repeated (labels p))))
      plans
  @ List.concat_map
      (fun p ->
        match p.answer with
        | Stream events ->
            (if List.mem (event_type p) lowered then
               [
                 Printf.sprintf "%s's events are %s, a component's name"
                   (route_name p.route) (event_type p);
               ]
             else [])
            @ List.map
                (fun n ->
                  Printf.sprintf "%s sends two events that are both %s"
                    (route_name p.route) n)
                (List.sort_uniq String.compare
                   (repeated (List.map (fun (n, _) -> constructor n) events)))
        | Value _ | Empty _ | Text | Socket _ -> [])
      plans

(* Text inside a doc comment, which ends at the first "*)" it holds. *)
let comment text =
  let b = Buffer.create (String.length text + 8) in
  String.iteri
    (fun i ch ->
      Buffer.add_char b ch;
      if
        Char.equal ch '*'
        && i + 1 < String.length text
        && Char.equal text.[i + 1] ')'
      then Buffer.add_char b ' ')
    text;
  "(** " ^ Buffer.contents b ^ " *)"

(* A string as Melange reads one whole, its UTF-8 kept: a plain literal is
   bytes to Melange, and a name or a path may hold more than ASCII. *)
let js s = "{js|" ^ s ^ "|js}"

let is_path (i : input) =
  match i.located with
  | D.In_path -> true
  | D.In_query | D.In_header | D.In_cookie -> false

let is_query (i : input) =
  match i.located with
  | D.In_query -> true
  | D.In_path | D.In_header | D.In_cookie -> false

let is_header (i : input) =
  match i.located with
  | D.In_header -> true
  | D.In_path | D.In_query | D.In_cookie -> false

type part = Literal of string | Param of string

(* [/items/{key}] as its literal parts and its parameters, in order. *)
let path_parts pattern inputs =
  let n = String.length pattern in
  let rec go i acc =
    let rest () = List.rev (Literal (String.sub pattern i (n - i)) :: acc) in
    match String.index_from_opt pattern i '{' with
    | None -> rest ()
    | Some brace -> (
        match String.index_from_opt pattern brace '}' with
        | None -> rest ()
        | Some close ->
            go (close + 1)
              (Param (String.sub pattern (brace + 1) (close - brace - 1))
              :: Literal (String.sub pattern i (brace - i))
              :: acc))
  in
  List.filter_map
    (function
      | Literal "" -> None
      | Literal s -> Some ("Route.literal " ^ js s)
      | Param name ->
          List.find_map
            (fun i ->
              if String.equal i.name name && is_path i then
                Some
                  (Printf.sprintf "Route.segment %s (%s_to_json %s)" (js name)
                     (S.Melange.name i.component)
                     i.label)
              else None)
            inputs)
    (go 0 [])

(* An OCaml list as printed: [[]], or its items between brackets. *)
let list = function
  | [] -> "[]"
  | items -> "[ " ^ String.concat "; " items ^ " ]"

let function_of p =
  let r = p.route in
  let c n = S.Melange.name n in
  let arg i =
    if i.required || is_path i then "~" ^ i.label else "?" ^ i.label
  in
  let given i =
    if i.required || is_path i then
      Printf.sprintf "(Some (%s_to_json %s))" (c i.component) i.label
    else Printf.sprintf "(Option.map %s_to_json %s)" (c i.component) i.label
  in
  let located is = List.filter is p.inputs in
  let body_args, body =
    match p.sends with
    | No_body -> ([], "Route.no_body")
    | Json { component; required = true } ->
        ( [ "~body" ],
          Printf.sprintf "(Route.json (Some (encode_%s body)))" (c component) )
    | Json { component; required = false } ->
        ( [ "?body" ],
          Printf.sprintf "(Route.json (Option.map encode_%s body))"
            (c component) )
    | Raw content_type ->
        ( [ "~body" ],
          Printf.sprintf "(Route.raw ~content_type:%s (Some body))"
            (js content_type) )
    | Form { component; files } ->
        let file (f : Dep.file) =
          let l = S.Melange.name f.name in
          let each =
            match (f.required, f.many) with
            | true, true -> Printf.sprintf "Array.to_list %s" l
            | true, false -> Printf.sprintf "[ %s ]" l
            | false, true ->
                Printf.sprintf "Option.fold ~none:[] ~some:Array.to_list %s" l
            | false, false -> Printf.sprintf "Option.to_list %s" l
          in
          ( (if f.required then "~" else "?") ^ l,
            Printf.sprintf "(%s, %s)" (js f.name) each )
        in
        let files = List.map file files in
        ( "~body" :: List.map fst files,
          Printf.sprintf "(Route.form (%s_to_json body) %s)" (c component)
            (list (List.map snd files)) )
  in
  let doc =
    match (r.summary, r.doc) with
    | Some s, Some d -> Some (s ^ "\n\n" ^ d)
    | Some s, None | None, Some s -> Some s
    | None, None -> None
  in
  let path = list (path_parts r.info.pattern p.inputs)
  and query =
    list
      (List.map
         (fun i -> Printf.sprintf "Route.query %s %s" (js i.name) (given i))
         (located is_query))
  and headers =
    list
      (List.map
         (fun i ->
           Printf.sprintf "Route.header %s %s"
             (js (String.lowercase_ascii i.name))
             (given i))
         (located is_header))
  and route = js (route_name r)
  and meth = js (Spindle_http.Meth.to_string r.info.meth) in
  let args extra =
    String.concat " "
      (("?origin" :: List.map arg (located is_path))
      @ List.map arg (located is_query)
      @ List.map arg (located is_header)
      @ body_args @ extra)
  in
  let request =
    Printf.sprintf
      "?origin ~route:%s ~meth:%s\n\
      \    ~path:%s\n\
      \    ~query:%s\n\
      \    ~headers:%s\n\
      \    ~body:%s"
      route meth path query headers body
  in
  let doc = match doc with Some d -> comment d ^ "\n" | None -> "" in
  let statuses ss = list (List.map string_of_int ss) in
  match p.answer with
  | Value _ | Empty _ | Text ->
      let answer =
        match p.answer with
        | Value (ss, component) ->
            Printf.sprintf "(Route.value %s decode_%s)" (statuses ss)
              (c component)
        | Empty ss -> Printf.sprintf "(Route.empty %s)" (statuses ss)
        | Text | Stream _ | Socket _ -> "Route.text_answer"
      in
      Printf.sprintf "%slet %s %s () =\n  Route.call %s\n    %s\n\n" doc
        r.operation_id (args []) request answer
  | Stream events ->
      let t = event_type p in
      let case (name, carries) =
        match carries with
        | Json_of component ->
            Printf.sprintf
              "String.equal name %s then Route.Stream.json decode_%s (fun x -> \
               (%s x : %s)) data"
              (js name) (c component) (constructor name) t
        | Text_of | Bytes_of ->
            Printf.sprintf "String.equal name %s then Ok (%s data : %s)"
              (js name) (constructor name) t
      in
      let variant (name, carries) =
        match carries with
        | Json_of component ->
            Printf.sprintf "%s of %s" (constructor name) (c component)
        | Text_of | Bytes_of -> constructor name ^ " of string"
      in
      Printf.sprintf
        "type %s = %s\n\n\
         %slet %s %s () =\n\
        \  Route.Stream.call %s\n\
        \    ~read:(fun name data ->\n\
         %s\n\
        \      else Error \"an event it never sends\")\n\
        \    ~on_event ()\n\n"
        t
        (String.concat " | " (List.map variant events))
        doc r.operation_id (args [ "~on_event" ]) request
        ("      if " ^ String.concat "\n      else if " (List.map case events))
  | Socket { subprotocol; client; server } ->
      let outgoing = function
        | Json_of component ->
            "(Route.Socket.json_out encode_" ^ c component ^ ")"
        | Text_of -> "Route.Socket.text_out"
        | Bytes_of -> "Route.Socket.binary_out"
      and incoming = function
        | Json_of component ->
            "(Route.Socket.json_in decode_" ^ c component ^ ")"
        | Text_of -> "Route.Socket.text_in"
        | Bytes_of -> "Route.Socket.binary_in"
      in
      Printf.sprintf
        "%slet %s %s () =\n\
        \  Route.Socket.call ?origin ~route:%s\n\
        \    ~path:%s\n\
        \    ~query:%s%s\n\
        \    ~write:%s\n\
        \    ~read:%s\n\
        \    ~on_message ()\n\n"
        doc r.operation_id (args [ "~on_message" ]) route path query
        (match subprotocol with
        | Some name -> "\n    ~subprotocol:" ^ js name
        | None -> "")
        (outgoing client) (incoming server)

let client
    ?(header = "Printed by Spindle from the server's routes. Do not edit.") app
    =
  let d = D.of_app app in
  match d.errors with
  | _ :: _ -> Error d.errors
  | [] -> (
      let own = ref [] in
      let plans = List.map (plan_of own) (List.filter callable d.routes) in
      let components = d.components @ List.rev !own in
      match clashes components plans with
      | _ :: _ as errors -> Error errors
      | [] ->
          let b = Buffer.create 65536 in
          Buffer.add_string b (S.Melange.components ~header components);
          Buffer.add_string b "\n";
          Buffer.add_string b Melange_route.text;
          Buffer.add_string b "\n(* ---- Each route ---- *)\n\n";
          List.iter (fun p -> Buffer.add_string b (function_of p)) plans;
          Ok (Buffer.contents b))
