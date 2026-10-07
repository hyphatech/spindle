module Media_type = Spindle_http.Media_type
module M = Spindle_http.Multipart

type file = {
  filename : string option;
  content_type : Media_type.t;
  content : string;
}

type parsed = { fields : (string * string) list; files : (string * file) list }

(* A part with a filename is a file. An empty file input arrives as an empty
   part with an empty filename, which is no file. *)
let of_parts parts =
  List.fold_right
    (fun ((p : M.part), content) acc ->
      match p.filename with
      | None -> { acc with fields = (p.name, content) :: acc.fields }
      | Some "" when String.equal content "" -> acc
      | Some filename ->
          {
            acc with
            files =
              ( p.name,
                {
                  filename =
                    (if String.equal filename "" then None else Some filename);
                  content_type = p.content_type;
                  content;
                } )
              :: acc.files;
          })
    parts
    { fields = []; files = [] }

(* A body held whole has nothing left to fail at. *)
type nothing = |

let split_parts ~boundary body =
  let delivered = ref false in
  let reader =
    M.create ~boundary (fun () ->
        if !delivered then (Ok None : (string option, nothing) result)
        else (
          delivered := true;
          Ok (Some body)))
  in
  let rec collect acc =
    match M.next reader with
    | Ok None -> Ok (List.rev acc)
    | Ok (Some part) ->
        let b = Buffer.create 256 in
        let rec read_content () =
          match M.read reader with
          | Ok (`Data s) ->
              Buffer.add_string b s;
              read_content ()
          | Ok `End -> Ok (Buffer.contents b)
          | Error e -> Error e
        in
        Result.bind (read_content ()) (fun c -> collect ((part, c) :: acc))
    | Error e -> Error e
  in
  Result.map_error
    (function
      | M.Malformed detail -> Multipart.refusal (Multipart.Malformed detail)
      | M.Head_too_large -> Refusal.too_large
      | M.Source (_ : nothing) -> .)
    (collect [])

(* Urlencoded, or multipart with its boundary, decided before the body is
   read. *)
let parsed_body =
  Dep_repr.make ~needs:[ Dep.Body Dep.Form ]
    ~codes:[ Refusal.Code.unsupported_media_type ]
    (fun (c : Dep_repr.context) ->
      let whole k held =
        match Body_repr.whole held with
        | Ok s -> k s
        | Error e -> Error (Body_repr.refusal e)
      in
      match
        Option.map Media_type.parse (Request.header c.request "content-type")
      with
      | None
      | Some
          (Ok { type_ = "application"; subtype = "x-www-form-urlencoded"; _ })
        ->
          Later
            (whole (fun s ->
                 Ok { fields = Spindle_http.Urlencoded.parse s; files = [] }))
      | Some (Ok ({ type_ = "multipart"; subtype = "form-data"; _ } as m)) -> (
          match M.boundary m with
          | Some boundary ->
              Later
                (whole (fun s -> Result.map of_parts (split_parts ~boundary s)))
          | None ->
              Now
                (Error
                   (Dep.problem ~at:"header.content-type" ~code:"malformed"
                      "This names no boundary.")))
      | Some (Ok _ | Error _) -> Now (Error Refusal.unsupported_media_type))

let field_path name = "form." ^ name

(* Every field and file reads [parsed_body], so a route that reads several
   reads the body once. *)
let from_body ~need pick read =
  Dep_repr.make ~inside:parsed_body.listed ~needs:[ need ] (fun c ->
      match Dep_repr.exec parsed_body c with
      | Now r -> Now (Result.bind r (fun p -> read (pick p)))
      | Later k ->
          Later (fun held -> Result.bind (k held) (fun p -> read (pick p))))

let values_named name list =
  List.filter_map
    (fun (k, v) -> if String.equal k name then Some v else None)
    list

let field name codec ~required ~many read =
  let need =
    Dep.Field
      {
        name;
        required;
        many;
        shape = Codec.shape codec;
        kind = Codec.kind codec;
        default = None;
      }
  in
  from_body ~need (fun p -> values_named name p.fields) read

(* A browser sends a form's text as UTF-8. *)
let parse_value name codec v =
  if not (String.is_valid_utf_8 v) then
    Error
      (Dep.problem ~at:(field_path name) ~code:"malformed" "This is not text.")
  else
    Option.to_result
      ~none:(Input.malformed ~at:(field_path name) codec)
      (Codec.parse codec v)

let optional name codec =
  field name codec ~required:false ~many:false (function
    | [] -> Ok None
    | v :: _ -> Result.map Option.some (parse_value name codec v))

let required name codec =
  field name codec ~required:true ~many:false (function
    | [] -> Error (Input.missing ~at:(field_path name))
    | v :: _ -> parse_value name codec v)

let list name codec =
  field name codec ~required:false ~many:true (fun vs ->
      List.fold_right
        (fun v acc ->
          match (parse_value name codec v, acc) with
          | Ok x, Ok l -> Ok (x :: l)
          | Error e, _ | _, Error e -> Error e)
        vs (Ok []))

let checked name =
  field name Codec.string ~required:false ~many:false (fun vs ->
      Ok (match vs with [] -> false | _ :: _ -> true))

let file_need name ~required ~many = Dep.File { name; required; many }

let file name =
  from_body
    ~need:(file_need name ~required:true ~many:false)
    (fun p -> values_named name p.files)
    (function
      | [] -> Error (Input.missing ~at:(field_path name)) | f :: _ -> Ok f)

let file_opt name =
  from_body
    ~need:(file_need name ~required:false ~many:false)
    (fun p -> values_named name p.files)
    (function [] -> Ok None | f :: _ -> Ok (Some f))

let files name =
  from_body
    ~need:(file_need name ~required:false ~many:true)
    (fun p -> values_named name p.files)
    (fun fs -> Ok fs)
