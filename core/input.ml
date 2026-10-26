(* A query parameter, a header and a cookie are read one way, differing only
   in where the text comes from. *)

type source = {
  where : string;  (** as a problem names it: [query], [header], [cookie] *)
  need : Dep.input -> Dep.need;
  read : Request.t -> string -> string list;
  field : bool;  (** a header's, whose lines are one field (RFC 9110 §5.2) *)
}

let query =
  {
    where = "query";
    need = (fun i -> Dep.Query i);
    read = Request.queries;
    field = false;
  }

let header =
  {
    where = "header";
    need = (fun i -> Dep.Header i);
    read =
      (fun r n ->
        let n = String.lowercase_ascii n in
        List.filter_map
          (fun (k, v) ->
            if String.equal k n then Some (String.trim v) else None)
          (Request.headers r));
    field = true;
  }

let cookie =
  {
    where = "cookie";
    need = (fun i -> Dep.Cookie i);
    read = (fun r n -> Option.to_list (Request.cookie r n));
    field = false;
  }

let input_path source name = source.where ^ "." ^ name

let input_dep ?default source name description ~required ~many =
  let at = input_path source name in
  Dep.of_request
    ~needs:
      [
        source.need
          {
            Dep.name;
            required;
            many;
            schema = Parameter.schema description;
            kind = Parameter.kind description;
            default = Option.map (Parameter.default ~at description) default;
          };
      ]

let missing ~at = Dep.problem ~at ~code:"required" "This is required."

(* The value's problems are its description's, each at the input's place. *)
let parse ~at description v =
  Result.map_error
    (fun problems ->
      Refusal.invalid
        (List.map
           (fun (p : Wiretype.Problem.t) ->
             {
               Refusal.at;
               code = Wiretype.Problem.code_to_string p.code;
               message = p.message;
             })
           problems))
    (Wiretype.of_text description v)

let parse_value source name description v =
  parse ~at:(input_path source name) description v

(* The one text an input names: a query's first value, or a header's field.
   A list's lines are joined by ", " (RFC 9110 §5.3), where its reader says
   it is one; any other field sent on two lines is an invalid message
   (§5.5), refused rather than read by its first line where a proxy may
   have read its last. *)
let one ?(joined = false) source name r =
  match source.read r name with
  | [] -> Ok None
  | [ v ] -> Ok (Some v)
  | v :: _ when not source.field -> Ok (Some v)
  | lines when joined -> Ok (Some (String.concat ", " lines))
  | _ :: _ ->
      Error
        (Dep.problem ~at:(input_path source name) ~code:"malformed"
           "This is one value, and was sent more than once.")

let optional ?joined source name description =
  input_dep source name description ~required:false ~many:false (fun r ->
      match one ?joined source name r with
      | Ok None -> Ok None
      | Ok (Some v) ->
          Result.map Option.some (parse_value source name description v)
      | Error e -> Error e)

let default source name description value =
  input_dep ~default:value source name description ~required:false ~many:false
    (fun r ->
      match one source name r with
      | Ok None -> Ok value
      | Ok (Some v) -> parse_value source name description v
      | Error e -> Error e)

let required source name description =
  input_dep source name description ~required:true ~many:false (fun r ->
      match one source name r with
      | Ok None -> Error (missing ~at:(input_path source name))
      | Ok (Some v) -> parse_value source name description v
      | Error e -> Error e)

(* One value that does not read is the input's one problem. *)
let list source name description =
  input_dep source name description ~required:false ~many:true (fun r ->
      List.fold_right
        (fun v acc ->
          match (parse_value source name description v, acc) with
          | Ok x, Ok l -> Ok (x :: l)
          | Error e, _ | _, Error e -> Error e)
        (source.read r name) (Ok []))

(* Read from what the route's path matched. [App.make] checks it exists,
   unless a [bind] hides it, so a missing one is a bug. *)
let param p =
  let (Path_repr.Param { name; description; _ }) = p in
  Dep_repr.make ~needs:[ Dep.Path name ] (fun c ->
      Dep_repr.Now
        (match List.assoc_opt name c.params with
        | None ->
            Error
              (Refusal.internal
                 ~detail:
                   (Printf.sprintf
                      "a dependency read the path parameter %s, which this \
                       route's path does not have"
                      name))
        | Some raw -> parse ~at:("path." ^ name) description raw))
