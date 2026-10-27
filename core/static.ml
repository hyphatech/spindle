type file = {
  at : string;  (** its own path, where its siblings are found *)
  body : string;
  content_type : string;
  tag : Spindle_http.Etag.t;
}

type t = {
  files : (string, file) Hashtbl.t;
      (** by the request path with its leading slash, so serving is a lookup;
          written while loading only *)
  index : string;
  shell : (file * string list) option;
  not_found : file option;
}

(* A browser keeps a copy and asks again each time, answered 304 while it
   is the same; keeping one longer is the application's policy (Cache). *)
let cache_revalidate = "no-cache"

(* A digest rather than a date: exact, and nothing to agree with. *)
let etag_of_body body =
  {
    Spindle_http.Etag.weak = false;
    opaque = Digest.BLAKE128.to_hex (Digest.BLAKE128.string body);
  }

(* What a build leaves beside a site -- [.env], [.git] -- is none of it;
   [.well-known] at the site's root is the site's by definition (RFC 8615
   §3), and below it is a dot-name like any other. *)
let is_dot_name ~at entry =
  String.starts_with ~prefix:"." entry
  && not (String.equal at "" && String.equal entry ".well-known")

(* A symlink is followed here, at startup, never at request time. *)
let rec walk_files dir ~dotfiles ~at ~add =
  List.iter
    (fun entry ->
      let skip = (not dotfiles) && is_dot_name ~at entry in
      let path = Eio.Path.(dir / entry) and at = at ^ "/" ^ entry in
      if not skip then
        match Eio.Path.kind ~follow:true path with
        | `Directory -> walk_files path ~dotfiles ~at ~add
        | `Regular_file -> add at (Eio.Path.load path)
        | _ -> ())
    (Eio.Path.read_dir dir)

let load ?(index = "index.html") ?(dotfiles = false) ?not_found ?shell
    ?(types = []) dir =
  let types =
    List.map (fun (ext, t) -> (String.lowercase_ascii ext, t)) types
  in
  let files = Hashtbl.create 128 in
  let add_file at body =
    Hashtbl.replace files at
      {
        at;
        body;
        content_type = File_types.content_type ~types at;
        tag = etag_of_body body;
      }
  in
  let find_named what = function
    | None -> Ok None
    | Some at -> (
        match Hashtbl.find_opt files at with
        | Some f -> Ok (Some f)
        | None ->
            Error
              (Format.asprintf "The %s, %s, is not in %a." what at Eio.Path.pp
                 dir))
  in
  match Eio.Path.is_directory dir with
  | false -> Error (Format.asprintf "%a is not a directory." Eio.Path.pp dir)
  | true -> (
      match walk_files dir ~dotfiles ~at:"" ~add:add_file with
      | exception (Eio.Io _ as e) ->
          Error
            (Format.asprintf "%a could not be read: %s." Eio.Path.pp dir
               (Printexc.to_string e))
      | () ->
          let ( let* ) = Result.bind in
          let* not_found = find_named "not-found document" not_found in
          let* shell =
            match shell with
            | None -> Ok None
            | Some (at, prefixes) ->
                Result.map
                  (Option.map (fun f -> (f, prefixes)))
                  (find_named "shell" (Some at))
          in
          Ok { files; index; shell; not_found })

let files t = Hashtbl.length t.files

(* A segment holding an encoded "/" names no file: it would be a second
   spelling of two segments. *)
let path_of_segments segments =
  if List.exists (fun s -> String.contains s '/') segments then None
  else Some ("/" ^ String.concat "/" segments)

let find_file t segments =
  match path_of_segments segments with
  | None -> `Missing
  | Some path -> (
      let is_under_shell (_, prefixes) =
        List.exists (fun prefix -> String.starts_with ~prefix path) prefixes
      in
      match t.shell with
      | Some ((f, _) as shell) when is_under_shell shell -> `Found f
      | Some _ | None -> (
          match Hashtbl.find_opt t.files path with
          | Some f -> `Found f
          | None -> (
              let index =
                if String.equal path "/" then "/" ^ t.index
                else path ^ "/" ^ t.index
              in
              match Hashtbl.find_opt t.files index with
              | Some f -> `Found f
              | None -> `Missing)))

(* A file with a precompressed sibling is several representations; all vary
   by Accept-Encoding. *)
let choose_representation t req f =
  let available =
    List.filter_map
      (fun (coding, ext) ->
        if Hashtbl.mem t.files (f.at ^ ext) then Some coding else None)
      File_types.siblings
  in
  let varies =
    match available with [] -> [] | _ :: _ -> [ ("vary", "Accept-Encoding") ]
  in
  match
    Option.bind (File_types.coding req ~available) (fun c ->
        Option.map
          (fun sibling -> (c, sibling))
          (Hashtbl.find_opt t.files (f.at ^ File_types.extension c)))
  with
  | Some (coding, sibling) ->
      ( { sibling with content_type = f.content_type },
        ("content-encoding", coding) :: varies )
  | None -> (f, varies)

(* Whole, in part or conditionally; the not-found document is an error page
   and is answered as it is. *)
let answer_file t req f =
  let f, coding_headers = choose_representation t req f in
  let v = { Conditional.tag = f.tag; modified = None }
  and headers =
    ("cache-control", cache_revalidate) :: File_types.nosniff :: coding_headers
  and length = String.length f.body in
  let decision = Conditional.decide req v ~length in
  match Conditional.bodiless_response v ~headers ~length decision with
  | Some r -> r
  | None -> (
      let headers = Conditional.representation_headers v ~headers in
      match decision with
      | Conditional.Part { first; last } ->
          Response.make ~status:`Partial_content ~content_type:f.content_type
            ~headers:
              (( "content-range",
                 Spindle_http.Range.content_range ~first ~last ~length )
              :: headers)
            (String.sub f.body first (last - first + 1))
      | Conditional.Whole | Conditional.Precondition_failed
      | Conditional.Not_modified | Conditional.Unsatisfiable ->
          Response.make ~content_type:f.content_type ~headers f.body)

let serve_segments t segments req =
  match find_file t segments with
  | `Found f -> Ok (answer_file t req f)
  | `Missing -> (
      match t.not_found with
      | Some f ->
          Ok
            (Response.make ~status:`Not_found ~content_type:f.content_type
               ~headers:
                 [ ("cache-control", cache_revalidate); File_types.nosniff ]
               f.body)
      | None -> Error Refusal.not_found)

let site_route ?(at = Path.root) site =
  let file = Path.rest "file" in
  Route_repr.get ~summary:"A file of the site"
    ~refuses:[ Refusal.Code.not_found ]
    Path.(at / file)
    Returns.response
    (Dep.map
       (fun ((segments, req), t) -> serve_segments t segments req)
       (Dep.both (Dep.both (Input.param file) Conditional.inputs) site))

let route ?at t = site_route ?at (Dep.return t)

(* Read by each start, into a resource of that instance alone. *)
let directory ?at ?index ?dotfiles ?not_found ?shell ?types path =
  let site = Dep.of_resource ("the directory " ^ path) in
  let r = site_route ?at site in
  {
    r with
    Route_repr.start =
      Some
        {
          read =
            (fun fs ->
              Result.map (Dep.resource site)
                (load ?index ?dotfiles ?not_found ?shell ?types
                   Eio.Path.(fs / path)));
          in_a_test =
            "loads it with Static.load and serves it with Static.route";
        };
  }
