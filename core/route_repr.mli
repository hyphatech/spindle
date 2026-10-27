(** A route: what it says of itself, its segments, and how it answers. Made only
    here, through {!Spindle.get} and its siblings; answered only by {!App}. What
    {!Route} is, underneath. *)

type param = {
  name : string;
  schema : Wiretype.Schema.t;
  kind : string option;
  unparsed : Path_repr.unparsed;
  rest : bool;
}

type info = {
  meth : Spindle_http.Meth.t;
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
}
(** What a route says of itself, which the document and the route table read. *)

type start = {
  read : Eio.Fs.dir_ty Eio.Path.t -> (Dep_repr.resource, string) result;
      (** run as the app starts, reading the filesystem: what it read, supplied
          as a resource of that instance, which the route reads *)
  in_a_test : string;
      (** what a test, which has no filesystem to start, does instead *)
}
(** A route that reads a directory when the server starts: {!Static.directory}'s
    and {!Files.directory}'s. *)

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

val input_key : Dep.need -> (string * string) option
(** Where an input is read and its name, by which two reads are one input: a
    header's name lower-cased, and a form's field and file sharing names. [None]
    for what is no named input -- a path parameter, a body, a custom need. *)

val framework_codes : info -> Refusal.Code.t list
(** The framework's own codes a route may answer, from what it reads: [invalid]
    where it reads typed inputs, the body's where it reads one, [cross_origin]
    for a method that changes something, and [busy] and [internal] anywhere --
    what its document lists, and so what it may refuse with undeclared. *)

val mark : info -> Request_repr.t -> Request_repr.t
(** The request, once the table has chosen this route, so a middleware can ask
    which. *)

val matched : Request_repr.t -> info option
(** The route a request matched, once the table has chosen. *)

val handle :
  t ->
  Request.t ->
  resources:Dep_repr.resources ->
  params:(string * string) list ->
  body:Body_repr.source ->
  Response.t

val make :
  Spindle_http.Meth.t ->
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?access_log:Logs.level ->
  ?compress:Compress_repr.t ->
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
  ?access_log:Logs.level ->
  ?compress:Compress_repr.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t

val post :
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?access_log:Logs.level ->
  ?compress:Compress_repr.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t

val put :
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?access_log:Logs.level ->
  ?compress:Compress_repr.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t

val patch :
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?access_log:Logs.level ->
  ?compress:Compress_repr.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t

val delete :
  ?refuses:Refusal.Code.t list ->
  ?summary:string ->
  ?doc:string ->
  ?tags:string list ->
  ?access_log:Logs.level ->
  ?compress:Compress_repr.t ->
  ('a, 'kind) Path.t ->
  'r Returns_repr.t ->
  'r Dep_repr.t ->
  t
