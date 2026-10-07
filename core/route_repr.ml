(* A route: what it says of itself, its segments, and how it answers. Made
   only here, through [Spindle.get] and its siblings; answered only by
   [App]. *)

module Meth = Spindle_http.Meth

type param = {
  name : string;
  shape : Codec.shape;
  kind : string option;
  or_not_found : bool;
  rest : bool;
}

type info = {
  meth : Meth.t;
  pattern : string;
  params : param list;
  needs : Dep.need list;
  credentials : Dep.credential list;
  returns : Returns.shape;
  codes : Refusal.Code.t list;
  opaque : bool;
  meta : Meta.t;
}

type t = {
  info : info;
  segments : Path_repr.segment list;
  run :
    Request.t ->
    params:(string * string) list ->
    body:Body_repr.source ->
    Response.t;
  start : (Eio.Fs.dir_ty Eio.Path.t -> (unit, string) result) option;
      (** run as the server starts, reading the filesystem: the directory
          [Static.directory] names *)
}

type Request_repr.matched += Matched of info

(* Set once the table has chosen, so a middleware can ask which route. *)
let mark info req = Request_repr.with_matched (Matched info) req

let matched req =
  match Request_repr.matched req with
  | Some (Matched info) -> Some info
  | Some _ | None -> None

let handle t req ~params ~body = t.run req ~params ~body

(* ------------------------------------------------------------------ *)
(* Making one: [Spindle.get] and its siblings are these *)

let params_of_segments segments =
  List.filter_map
    (function
      | Path_repr.Parameter { name; shape; kind; or_not_found; parses = _ } ->
          Some { name; shape; kind; or_not_found; rest = false }
      | Path_repr.Rest name ->
          Some
            {
              name;
              shape = Codec.String;
              kind = Some "path";
              or_not_found = false;
              rest = true;
            }
      | Path_repr.Literal _ -> None)
    segments

let meta_of ?summary ?doc ?tags ?(meta = Meta.empty) () =
  let add_if key = function Some v -> Meta.add key v | None -> Fun.id in
  meta
  |> add_if Meta.summary summary
  |> add_if Meta.doc doc |> add_if Meta.tags tags

let make meth ?(refuses = []) ?summary ?doc ?tags ?meta path returns inputs =
  let pattern = Path.pattern path in
  let segments = Path_repr.segments path in
  let table = Dep_repr.needs_table inputs in
  {
    info =
      {
        meth;
        pattern;
        params = params_of_segments segments;
        needs = Dep.needs inputs;
        credentials = Dep.credentials inputs;
        returns = Returns_repr.shape returns;
        codes = refuses @ Dep.codes inputs;
        opaque = Dep.opaque inputs;
        meta = meta_of ?summary ?doc ?tags ?meta ();
      };
    segments;
    run =
      (fun req ~params ~body ->
        let outgoing = Dep_repr.outgoing pattern in
        let response =
          match Returns_repr.upgrade returns req with
          | Error refusal -> Response.refusal refusal
          | Ok upgrade -> (
              match Dep_repr.run inputs ~table req ~params ~outgoing ~body with
              | Error refusal -> Response.refusal refusal
              | Ok r ->
                  Returns_repr.respond returns ~pattern ~path:(Request.path req)
                    ~upgrade ~cookies:outgoing.cookies ~headers:outgoing.headers
                    r)
        in
        outgoing.sent <- true;
        response);
    start = None;
  }

let get ?refuses = make `GET ?refuses
let post ?refuses = make `POST ?refuses
let put ?refuses = make `PUT ?refuses
let patch ?refuses = make `PATCH ?refuses
let delete ?refuses = make `DELETE ?refuses
