module Range = Spindle_http.Range
module L = (val Logs.src_log Log.http : Logs.LOG)

type options = {
  index : string option;
  dotfiles : bool;
  download : bool;
  types : (string * string) list;
}

(* Refused before anything is opened: a step elsewhere, a hidden file, or a
   byte that ends a name. *)
let is_refused_segment ~dotfiles segment =
  String.equal segment "" || String.equal segment "."
  || String.equal segment ".."
  || ((not dotfiles) && Char.equal segment.[0] '.')
  || String.exists (function '/' | '\\' | '\000' -> true | _ -> false) segment

(* As it is on disk now, by its path beneath the directory. *)
type file = { rel : string; name : string; size : int; mtime : float }

(* A directory is its index, where one is named, never a listing. *)
let lookup dir o segments =
  let stat_entry rel name =
    let st = Eio.Path.stat ~follow:true Eio.Path.(dir / rel) in
    match st.kind with
    | `Regular_file ->
        `File
          { rel; name; size = Optint.Int63.to_int st.size; mtime = st.mtime }
    | `Directory -> `Directory
    | _ -> `Missing
  in
  let rel, name =
    match List.rev segments with
    | [] -> (".", "")
    | last :: _ -> (String.concat "/" segments, last)
  in
  match (stat_entry rel name, o.index) with
  | `File f, _ -> Some f
  | `Directory, Some index -> (
      let rel =
        match segments with [] -> index | _ :: _ -> rel ^ "/" ^ index
      in
      match stat_entry rel index with
      | `File f -> Some f
      | `Directory | `Missing -> None)
  | `Directory, None | `Missing, _ -> None

(* Missing, outside the subtree (a symlink out of it), unreadable, or under a
   file rather than a directory are all not found to a request. Eio reports
   the last as the system's own error, not as one of [Eio.Fs]'s. *)
let find_file root o segments =
  match Eio.Path.with_subtree root (fun dir -> lookup dir o segments) with
  | found -> Ok found
  | exception
      Eio.Io
        ( ( Eio.Fs.E
              (Eio.Fs.Not_found _ | Eio.Fs.Permission_denied _ | Eio.Fs.Symlink)
          | Eio.Exn.X (Eio_unix.Unix_error (Unix.ENOTDIR, _, _)) ),
          _ ) ->
      Ok None
  | exception (Eio.Io _ as e) -> Error (Printexc.to_string e)

(* A strong tag of size and nanosecond time, since a resumed download
   matches only a strong one. *)
let validators f =
  {
    Conditional.tag =
      {
        Spindle_http.Etag.weak = false;
        opaque =
          Printf.sprintf "%x-%Lx" f.size (Int64.of_float (f.mtime *. 1e9));
      };
    modified_ms = Some (Float.to_int (Float.floor (f.mtime *. 1000.)));
  }

(* The largest read sent at once. *)
let read_bytes = 65_536

(* Opened again as the body is sent, and read only if it is still the file
   the head described; a replaced one sends nothing, and the declared length
   then closes the connection. *)
let send_file root f ~first ~count send =
  let unchanged (st : Eio.File.Stat.t) =
    Optint.Int63.to_int st.size = f.size && Float.equal st.mtime f.mtime
  in
  let send_range file =
    let buf = Cstruct.create (max 1 (min read_bytes count)) in
    let rec go at left =
      if left = 0 then Ok ()
      else
        let n =
          Eio.File.pread file ~file_offset:(Optint.Int63.of_int at)
            [ Cstruct.sub buf 0 (min left (Cstruct.length buf)) ]
        in
        match send (Cstruct.to_string ~len:n buf) with
        | Ok () -> go (at + n) (left - n)
        | Error Response.Gone -> Error Response.Gone
    in
    go first count
  in
  let log_changed () =
    L.info (fun m -> m "%s changed while it was sent" f.rel);
    Ok ()
  in
  match
    Eio.Path.with_subtree root (fun dir ->
        Eio.Path.with_open_in
          Eio.Path.(dir / f.rel)
          (fun file ->
            if unchanged (Eio.File.stat file) then send_range file
            else log_changed ()))
  with
  | sent -> sent
  | exception End_of_file -> log_changed ()
  | exception (Eio.Io _ as e) ->
      L.warn (fun m ->
          m "%s could not be read: %s" f.rel (Printexc.to_string e));
      Ok ()

(* RFC 6266: a quoted string where the name is printable ASCII; otherwise
   that with other bytes made [_], beside RFC 8187's UTF-8 [filename*]. *)
let is_plain_char c =
  let n = Char.code c in
  n >= 0x20 && n < 0x7f && (not (Char.equal c '"')) && not (Char.equal c '\\')

let is_attr_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' -> true
  | '!' | '#' | '$' | '&' | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~' ->
      true
  | _ -> false

let content_disposition name =
  if String.for_all is_plain_char name then
    Printf.sprintf "attachment; filename=\"%s\"" name
  else
    let fallback =
      String.map (fun c -> if is_plain_char c then c else '_') name
    in
    let encoded = Buffer.create (String.length name * 3) in
    String.iter
      (fun c ->
        if is_attr_char c then Buffer.add_char encoded c
        else Buffer.add_string encoded (Printf.sprintf "%%%02X" (Char.code c)))
      name;
    Printf.sprintf "attachment; filename=\"%s\"; filename*=UTF-8''%s" fallback
      (Buffer.contents encoded)

(* A file with a precompressed sibling is several representations, each
   looked for beneath the subtree; all vary by Accept-Encoding. *)
let choose_representation root req f =
  let precompressed ext =
    match
      Eio.Path.with_subtree root (fun dir ->
          let rel = f.rel ^ ext in
          let st = Eio.Path.stat ~follow:true Eio.Path.(dir / rel) in
          match st.kind with
          | `Regular_file ->
              Some
                {
                  f with
                  rel;
                  size = Optint.Int63.to_int st.size;
                  mtime = st.mtime;
                }
          | _ -> None)
    with
    | found -> found
    | exception Eio.Io _ -> None
  in
  let found =
    List.filter_map
      (fun (coding, ext) ->
        Option.map (fun s -> (coding, s)) (precompressed ext))
      File_types.siblings
  in
  let varies =
    match found with [] -> [] | _ :: _ -> [ ("vary", "Accept-Encoding") ]
  in
  match File_types.coding req ~available:(List.map fst found) with
  | Some coding -> (
      match List.assoc_opt coding found with
      | Some s -> (s, ("content-encoding", coding) :: varies)
      | None -> (f, varies))
  | None -> (f, varies)

let answer_file root o req segments =
  if List.exists (is_refused_segment ~dotfiles:o.dotfiles) segments then
    Error Refusal.not_found
  else
    match find_file root o segments with
    | Error detail -> Error (Refusal.internal ~detail)
    | Ok None -> Error Refusal.not_found
    | Ok (Some original) -> (
        let f, coding_headers = choose_representation root req original in
        let v = validators f
        and headers = ("cache-control", "no-cache") :: coding_headers in
        let decision = Conditional.decide req v ~length:f.size in
        match
          Conditional.bodiless_response v ~headers ~length:f.size decision
        with
        | Some r -> Ok r
        | None ->
            let headers =
              Conditional.representation_headers v ~headers
              @
              if o.download then
                [ ("content-disposition", content_disposition f.name) ]
              else []
            in
            let status, headers, first, count =
              match decision with
              | Conditional.Part { first; last } ->
                  ( `Partial_content,
                    ( "content-range",
                      Range.content_range ~first ~last ~length:f.size )
                    :: headers,
                    first,
                    last - first + 1 )
              | Conditional.Whole | Conditional.Precondition_failed
              | Conditional.Not_modified | Conditional.Unsatisfiable ->
                  (`OK, headers, 0, f.size)
            in
            Ok
              (Response.stream ~status ~headers
                 ~content_type:
                   (File_types.content_type ~types:o.types original.name)
                 ~length:count
                 (send_file root f ~first ~count)))

let files_route ?(at = Path.root) o root =
  let file = Path.rest "file" in
  Route_repr.get ~summary:"A file from disk"
    Path.(at / file)
    Returns.response
    (Dep.map
       (fun (segments, req) ->
         match root () with
         | Some root -> answer_file root o req segments
         | None ->
             Error
               (Refusal.internal
                  ~detail:
                    "a directory served before it was started: App.start \
                     checks it, and Spindle.serve calls that"))
       (Dep.both (Input.param file) Conditional.inputs))

let options ?index ?(dotfiles = false) ?(download = false) ?(types = []) () =
  {
    index;
    dotfiles;
    download;
    types = List.map (fun (ext, t) -> (String.lowercase_ascii ext, t)) types;
  }

let route ?at ?index ?dotfiles ?download ?types root =
  files_route ?at (options ?index ?dotfiles ?download ?types ()) (fun () ->
      Some root)

(* Written once, as the server starts, before it accepts anything. *)
let directory ?at ?index ?dotfiles ?download ?types path =
  let root = Atomic.make None in
  let r =
    files_route ?at (options ?index ?dotfiles ?download ?types ()) (fun () ->
        Atomic.get root)
  in
  {
    r with
    Route_repr.start =
      Some
        (fun fs ->
          let dir = Eio.Path.(fs / path) in
          if Eio.Path.is_directory dir then (
            Atomic.set root (Some dir);
            Ok ())
          else Error (Format.asprintf "%a is not a directory." Eio.Path.pp dir));
  }
