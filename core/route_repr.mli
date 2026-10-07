(** A route: what it says of itself, its segments, and how it answers. Made only
    here, through {!Spindle.get} and its siblings; answered only by {!App}. What
    {!Route} is, underneath. *)

type param = {
  name : string;
  shape : Codec.shape;
  kind : string option;
  or_not_found : bool;
  rest : bool;
}

type info = {
  meth : Spindle_http.Meth.t;
  pattern : string;
  params : param list;
  needs : Dep.need list;
  credentials : Dep.credential list;
  returns : Returns.shape;
  codes : Refusal.Code.t list;
  opaque : bool;
  meta : Meta.t;
}
(** What a route says of itself, which the document and the route table read. *)

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
          {!Static.directory} names *)
}

val mark : info -> Request_repr.t -> Request_repr.t
(** The request, once the table has chosen this route, so a middleware can ask
    which. *)

val matched : Request_repr.t -> info option
(** The route a request matched, once the table has chosen. *)

val handle :
  t ->
  Request.t ->
  params:(string * string) list ->
  body:Body_repr.source ->
  Response.t

val make :
  Spindle_http.Meth.t ->
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?meta:Meta.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t
(** As {!Spindle.route}. *)

val get :
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?meta:Meta.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t

val post :
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?meta:Meta.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t

val put :
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?meta:Meta.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t

val patch :
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?meta:Meta.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t

val delete :
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?meta:Meta.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t
