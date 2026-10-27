(* A route: what it says of itself, its segments, and how it answers. Made
   only here, through [Spindle.get] and its siblings; answered only by
   [App]. *)

module Meth = Spindle_http.Meth
module Code = Refusal.Code

type param = {
  name : string;
  schema : Wiretype.Schema.t;
  kind : string option;
  unparsed : Path_repr.unparsed;
  rest : bool;
}

type info = {
  meth : Meth.t;
  pattern : string;
  params : param list;
  needs : Dep.need list;
  credentials : Dep.credential list;
  access : Dep_repr.access list;
  returns : Returns.shape;
  codes : Refusal.Code.t list;
  opaque : bool;
  summary : string option;
  doc : string option;
  tags : string list;
  access_log : Logs.level;
  compress : Compress_repr.t option;
  cors : Cors_repr.t option;
  limits : Limits_repr.route;
}

type start = {
  read : Eio.Fs.dir_ty Eio.Path.t -> (Dep_repr.resource, string) result;
  in_a_test : string;
}

type t = {
  info : info;
  segments : Path_repr.segment list;
  run :
    Request.t ->
    resources:Dep_repr.resources ->
    params:(string * string) list ->
    body:Body_repr.source ->
    Response.t;
  resources_read : (int * string) list;
      (** what it reads outside a [bind] ({!Dep_repr.resources_read}) *)
  start : start option;
}

type Request_repr.matched += Matched of info

(* Set once the table has chosen, so a middleware can ask which route. *)
let mark info req = Request_repr.with_matched (Matched info) req

let matched req =
  match Request_repr.matched req with
  | Some (Matched info) -> Some info
  | Some _ | None -> None

let handle t req ~resources ~params ~body = t.run req ~resources ~params ~body

(* ------------------------------------------------------------------ *)
(* Making one: [Spindle.get] and its siblings are these *)

let params_of_segments segments =
  List.filter_map
    (function
      | Path_repr.Parameter { name; schema; kind; unparsed; parses = _ } ->
          Some { name; schema; kind; unparsed; rest = false }
      | Path_repr.Rest name ->
          Some
            {
              name;
              schema = Parameter.schema Path_repr.rest;
              kind = Some "path";
              unparsed = Path_repr.Invalid;
              rest = true;
            }
      | Path_repr.Literal _ -> None)
    segments

(* An input is one by where it is read and its name, a header's without
   case (RFC 9110 §5.1), as OpenAPI holds an operation's parameters unique;
   a field and a file share a form's names. *)
let input_key = function
  | Dep.Query i -> Some ("the query parameter", i.name)
  | Dep.Header i -> Some ("the header", String.lowercase_ascii i.name)
  | Dep.Cookie i -> Some ("the cookie", i.name)
  | Dep.Field i -> Some ("the form's field", i.name)
  | Dep.File f -> Some ("the form's field", f.name)
  | Dep.Path _ | Dep.Body _ | Dep.Custom _ | Dep.Resource _ -> None

(* Two reads are one input where the document would say the same of
   both. *)
let same_schema a b =
  let said s = Wiretype.Value.to_string (Wiretype.Schema.Json_schema.of_t s) in
  String.equal (said a) (said b)

(* Two reads that agree are one input, required where either is; one that
   stands in a default where the other may not is still that default. *)
let merge_input (a : Dep.input) (b : Dep.input) =
  let agree =
    same_schema a.schema b.schema
    && Option.equal String.equal a.kind b.kind
    && Bool.equal a.many b.many
    &&
    match (a.default, b.default) with
    | Some x, Some y ->
        String.equal (Wiretype.Value.to_string x) (Wiretype.Value.to_string y)
    | Some _, None | None, Some _ | None, None -> true
  in
  if not agree then None
  else
    let required = a.required || b.required in
    Some
      {
        a with
        required;
        default =
          (if required then None
           else match a.default with Some _ -> a.default | None -> b.default);
      }

let merge_need a b =
  match (a, b) with
  | Dep.Query a, Dep.Query b ->
      Option.map (fun i -> Dep.Query i) (merge_input a b)
  | Dep.Header a, Dep.Header b ->
      Option.map (fun i -> Dep.Header i) (merge_input a b)
  | Dep.Cookie a, Dep.Cookie b ->
      Option.map (fun i -> Dep.Cookie i) (merge_input a b)
  | Dep.Field a, Dep.Field b ->
      Option.map (fun i -> Dep.Field i) (merge_input a b)
  | Dep.File a, Dep.File b when Bool.equal a.many b.many ->
      Some (Dep.File { a with required = a.required || b.required })
  | ( ( Dep.Query _ | Dep.Header _ | Dep.Cookie _ | Dep.Field _ | Dep.File _
      | Dep.Path _ | Dep.Body _ | Dep.Custom _ | Dep.Resource _ ),
      _ ) ->
      None

let same_key a b =
  match (input_key a, input_key b) with
  | Some (w, n), Some (w', n') -> String.equal w w' && String.equal n n'
  | Some _, None | None, Some _ | None, None -> false

(* Each input once, where it is first read; two reads that disagree are both
   kept, for [App.make] to refuse. *)
let merge_needs needs =
  List.fold_left
    (fun acc need ->
      let rec into = function
        | [] -> None
        | m :: rest when same_key m need ->
            Option.map (fun merged -> merged :: rest) (merge_need m need)
        | m :: rest -> Option.map (List.cons m) (into rest)
      in
      match into acc with Some acc -> acc | None -> acc @ [ need ])
    [] needs

let reads_inputs (i : info) =
  (match i.params with [] -> false | _ :: _ -> true)
  || List.exists
       (function
         | Dep.Query _ | Dep.Header _ | Dep.Cookie _ | Dep.Field _ | Dep.File _
         | Dep.Body _ ->
             true
         | Dep.Path _ | Dep.Custom _ | Dep.Resource _ -> false)
       i.needs

let framework_codes (i : info) =
  let reads_body =
    List.exists (function Dep.Body _ -> true | _ -> false) i.needs
  in
  let is_unsafe =
    match i.meth with
    | `GET | `HEAD | `OPTIONS | `TRACE -> false
    | `POST | `PUT | `PATCH | `DELETE | `CONNECT | `Other _ -> true
  in
  let is_websocket =
    match i.returns with
    | Returns.Websocket _ -> true
    | Returns.Json _ | Json_response _ | Html | Text | Empty _
    | Empty_response _ | Response | Events _ ->
        false
  in
  List.concat
    [
      (if reads_inputs i || is_websocket then [ Code.invalid ] else []);
      (if is_websocket then [ Code.upgrade_required ] else []);
      (if reads_body then [ Code.unreadable; Code.too_large ] else []);
      (if is_unsafe || is_websocket then [ Code.cross_origin ] else []);
      [ Code.busy; Code.internal ];
    ]

let make meth ?(refuses = []) ?summary ?doc ?(tags = [])
    ?(access_log = Logs.Info) ?compress ?cors ?(limits = Limits_repr.no_route)
    path returns inputs =
  let pattern = Path.pattern path in
  let segments = Path_repr.segments path in
  let table = Dep_repr.needs_table inputs in
  {
    info =
      {
        meth;
        pattern;
        params = params_of_segments segments;
        needs = merge_needs (Dep.needs inputs);
        credentials = Dep.credentials inputs;
        access = Dep_repr.access inputs;
        returns = Returns_repr.shape returns;
        codes = refuses @ Dep.codes inputs;
        opaque = Dep.opaque inputs;
        summary;
        doc;
        tags;
        access_log;
        compress;
        cors;
        limits;
      };
    segments;
    run =
      (fun req ~resources ~params ~body ->
        let outgoing = Dep_repr.outgoing pattern in
        let response =
          match Returns_repr.upgrade returns req with
          | Error refusal -> Response.refusal refusal
          | Ok upgrade -> (
              match
                Dep_repr.run inputs ~table ~resources req ~params ~outgoing
                  ~body ~limits
              with
              | Error refusal -> Response.refusal refusal
              | Ok r ->
                  Returns_repr.respond returns ~pattern ~path:(Request.path req)
                    ~upgrade ~cookies:outgoing.cookies ~headers:outgoing.headers
                    r)
        in
        outgoing.sent <- true;
        response);
    resources_read = Dep_repr.resources_read inputs;
    start = None;
  }

let get ?refuses = make `GET ?refuses
let post ?refuses = make `POST ?refuses
let put ?refuses = make `PUT ?refuses
let patch ?refuses = make `PATCH ?refuses
let delete ?refuses = make `DELETE ?refuses
