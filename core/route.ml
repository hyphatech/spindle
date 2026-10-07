module Websocket = Spindle_http.Websocket
module Status = Spindle_http.Status
module Meth = Spindle_http.Meth
include Route_repr

type ('r, 'a, 'k) maker =
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?meta:Meta.t ->
  ('a, 'k) Path.t ->
  'r Returns.t ->
  'r Dep.t ->
  t

let info t = t.info

(* ------------------------------------------------------------------ *)
(* Printing *)

let shape_to_string = function
  | Codec.String -> "string"
  | Codec.Integer -> "integer"
  | Codec.Boolean -> "boolean"
  | Codec.Enum words -> String.concat " | " words

let type_to_string shape kind =
  match kind with
  | Some k -> Printf.sprintf "%s (%s)" (shape_to_string shape) k
  | None -> shape_to_string shape

let input_to_string where (i : Dep.input) =
  Printf.sprintf "%s %s%s: %s%s" where i.name
    (if i.required then "" else "?")
    (type_to_string i.shape i.kind)
    (if i.many then ", repeated" else "")

let need_to_string = function
  | Dep.Path n -> "path " ^ n
  | Dep.Query i -> input_to_string "query" i
  | Dep.Header i -> input_to_string "header" i
  | Dep.Cookie i -> input_to_string "cookie" i
  | Dep.Field i -> input_to_string "form" i
  | Dep.File { name; required; many } ->
      Printf.sprintf "form %s%s: file%s" name
        (if required then "" else "?")
        (if many then "s" else "")
  | Dep.Body Dep.Form -> "body, as a form"
  | Dep.Body Dep.Multipart -> "body, a part at a time"
  | Dep.Body Dep.Raw -> "body"
  | Dep.Body Dep.Stream -> "body, as it arrives"
  | Dep.Body (Dep.Json { description; examples = _ }) ->
      "body " ^ Wiretype.name description
  | Dep.Custom { name; doc = _ } -> name

let statuses_to_string statuses =
  String.concat " or "
    (List.map (fun (s, _) -> string_of_int (Status.to_int s)) statuses)

let returns_to_string = function
  | Returns.Json { status; description; examples = _ } ->
      Printf.sprintf "%d %s" (Status.to_int status) (Wiretype.name description)
  | Returns.Json_response { statuses; description; examples = _ } ->
      Printf.sprintf "%s %s"
        (statuses_to_string statuses)
        (Wiretype.name description)
  | Returns.Html -> "a page"
  | Returns.Text -> "text"
  | Returns.Empty status -> Printf.sprintf "nothing, %d" (Status.to_int status)
  | Returns.Empty_response statuses -> "nothing, " ^ statuses_to_string statuses
  | Returns.Response -> "a response of its own"
  | Returns.Events declared ->
      "events " ^ String.concat ", " (List.map Event.declared_name declared)
  | Returns.Websocket protocol -> (
      match Websocket.subprotocol protocol with
      | Some name -> "a WebSocket, " ^ name
      | None -> "a WebSocket")

let pp_info ppf i =
  let print_line label = function
    | [] -> ()
    | items -> Format.fprintf ppf "@,  %s: %s" label (String.concat ", " items)
  in
  Format.fprintf ppf "@[<v>%s %s" (Meth.to_string i.meth) i.pattern;
  Option.iter (Format.fprintf ppf "  -- %s") (Meta.find Meta.summary i.meta);
  print_line "path"
    (List.map
       (fun p ->
         Printf.sprintf "%s: %s%s" p.name
           (type_to_string p.shape p.kind)
           (if p.or_not_found then ", or not this route"
            else if p.rest then ", the rest of the path"
            else ""))
       i.params);
  print_line "reads"
    (List.filter_map
       (function Dep.Path _ -> None | n -> Some (need_to_string n))
       i.needs
    @ if i.opaque then [ "and more it does not say" ] else []);
  print_line "credentials"
    (List.map (fun (c : Dep.credential) -> c.scheme) i.credentials);
  print_line "returns" [ returns_to_string i.returns ];
  print_line "refuses"
    (List.map
       (fun c ->
         Printf.sprintf "%d %s"
           (Status.to_int (Refusal.Code.status c))
           (Refusal.Code.name c))
       (List.sort_uniq
          (fun a b ->
            String.compare (Refusal.Code.name a) (Refusal.Code.name b))
          i.codes));
  print_line "tags" (Option.value (Meta.find Meta.tags i.meta) ~default:[]);
  Format.fprintf ppf "@]"
