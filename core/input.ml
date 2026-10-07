(* A query parameter, a header and a cookie are read one way, differing only
   in where the text comes from. *)

type source = {
  where : string;  (** as a problem names it: [query], [header], [cookie] *)
  need : Dep.input -> Dep.need;
  read : Request.t -> string -> string list;
}

let query =
  { where = "query"; need = (fun i -> Dep.Query i); read = Request.queries }

let header =
  {
    where = "header";
    need = (fun i -> Dep.Header i);
    read = (fun r n -> Option.to_list (Request.header r n));
  }

let cookie =
  {
    where = "cookie";
    need = (fun i -> Dep.Cookie i);
    read = (fun r n -> Option.to_list (Request.cookie r n));
  }

let input_dep source name codec ~required ~many =
  Dep.of_request
    ~needs:
      [
        source.need
          {
            Dep.name;
            required;
            many;
            shape = Codec.shape codec;
            kind = Codec.kind codec;
          };
      ]

let input_path source name = source.where ^ "." ^ name

let malformed ~at codec =
  Dep.problem ~at ~code:"malformed" ("This is not " ^ Codec.expects codec ^ ".")

let missing ~at = Dep.problem ~at ~code:"required" "This is required."

let parse_value source name codec v =
  Option.to_result
    ~none:(malformed ~at:(input_path source name) codec)
    (Codec.parse codec v)

let optional source name codec =
  input_dep source name codec ~required:false ~many:false (fun r ->
      match source.read r name with
      | [] -> Ok None
      | v :: _ -> Result.map Option.some (parse_value source name codec v))

let required source name codec =
  input_dep source name codec ~required:true ~many:false (fun r ->
      match source.read r name with
      | [] -> Error (missing ~at:(input_path source name))
      | v :: _ -> parse_value source name codec v)

(* One value that does not parse is the input's one problem. *)
let list source name codec =
  input_dep source name codec ~required:false ~many:true (fun r ->
      List.fold_right
        (fun v acc ->
          match (parse_value source name codec v, acc) with
          | Ok x, Ok l -> Ok (x :: l)
          | Error e, _ | _, Error e -> Error e)
        (source.read r name) (Ok []))

(* Read from what the route's path matched. [App.make] checks it exists,
   unless a [bind] hides it, so a missing one is a bug. *)
let param p =
  let (Path_repr.Param { name; codec; _ }) = p in
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
        | Some raw ->
            Option.to_result
              ~none:(malformed ~at:("path." ^ name) codec)
              (Codec.parse codec raw)))
