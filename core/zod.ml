module D = Described

let is_identifier s =
  String.length s > 0
  && (match s.[0] with
    | 'a' .. 'z' | 'A' .. 'Z' | '_' | '$' -> true
    | _ -> false)
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '$' -> true | _ -> false)
       s

let object_key s = if is_identifier s then s else Out.json_string s
let schema indent s = Wiretype.Schema.Zod.of_t ~indent s

let codes_enum (d : D.t) =
  List.sort_uniq String.compare (List.map Refusal.Code.name d.codes)

(* One status is [status: 201]; several share one body and are listed. *)
let statuses_entry = function
  | [ (status, _) ] -> Printf.sprintf "status: %d" status
  | statuses ->
      Printf.sprintf "statuses: [%s]"
        (String.concat ", " (List.map (fun (s, _) -> string_of_int s) statuses))

let route_entry (r : D.route) =
  let answer =
    match r.returns with
    | D.Value { schema = s; statuses; _ } ->
        Printf.sprintf "{ %s, schema: %s }" (statuses_entry statuses)
          (schema "    " s)
    | D.Html -> "\"html\""
    | D.Text -> "\"text\""
    | D.Empty statuses -> Printf.sprintf "{ %s }" (statuses_entry statuses)
    | D.Response -> "\"response\""
    | D.Events events ->
        "{ events: { "
        ^ String.concat ", "
            (List.map
               (fun (n, data) ->
                 object_key n ^ ": "
                 ^
                 match data with
                 | D.Json_data s -> schema "    " s
                 | D.Text_data | D.Binary_data -> "z.string()")
               events)
        ^ " } }"
    | D.Socket { subprotocol; client; server } ->
        let message_schema = function
          | D.Json_data s -> schema "    " s
          | D.Text_data -> "z.string()"
          | D.Binary_data -> "z.instanceof(ArrayBuffer)"
        in
        Printf.sprintf "{ websocket: { %sclient: %s, server: %s } }"
          (match subprotocol with
          | Some n -> "subprotocol: " ^ Out.json_string n ^ ", "
          | None -> "")
          (message_schema client) (message_schema server)
  in
  let body =
    match r.body with
    | Some (D.Json_body { schema = s; _ }) -> schema "    " s
    | Some (D.Form_body { fields; files = [] }) -> schema "    " fields
    | Some (D.Form_body { fields; files }) ->
        Printf.sprintf "z.extend(%s, { %s })" (schema "    " fields)
          (String.concat ", "
             (List.map
                (fun (f : Dep.file) ->
                  let one = "z.instanceof(Blob)" in
                  let one = if f.many then "z.array(" ^ one ^ ")" else one in
                  Out.json_string f.name ^ ": "
                  ^ if f.required then one else "z.optional(" ^ one ^ ")")
                files))
    | Some D.Parts_body -> "z.instanceof(FormData)"
    | Some D.Raw_body -> "z.string()"
    | None -> "null"
  in
  Printf.sprintf "  %s: {\n    body: %s,\n    answer: %s,\n  },\n"
    (Out.json_string
       (Spindle_http.Meth.to_string r.info.meth ^ " " ^ r.info.pattern))
    body answer

let module_ ?(header = "Generated from the server's routes. Do not edit.") app =
  let d = D.of_app app in
  match d.errors with
  | _ :: _ -> Error d.errors
  | [] ->
      let b = Buffer.create 16384 in
      Buffer.add_string b ("/* " ^ header ^ " */\n\n");
      Buffer.add_string b "import { z } from \"zod/mini\";\n\n";
      Buffer.add_string b (Wiretype.Schema.Zod.components d.components);
      Buffer.add_string b
        (Printf.sprintf
           "/** Every code a route may refuse with. */\n\
            export const CodeSchema = z.enum([\n\
            %s]);\n\
            export type Code = z.infer<typeof CodeSchema>;\n\n"
           (String.concat ""
              (List.map
                 (fun c -> "  " ^ Out.json_string c ^ ",\n")
                 (codes_enum d))));
      Buffer.add_string b
        "/** Each route, by method and pattern: the body it reads, and what it \
         answers. */\n\
         export const routes = {\n";
      List.iter (fun r -> Buffer.add_string b (route_entry r)) d.routes;
      Buffer.add_string b "} as const;\n";
      Ok (Buffer.contents b)
