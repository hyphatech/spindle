(** An application's routes as the two printers read them: every description
    walked, the answers first and then the bodies, so a component a response and
    a request share takes the response's name. *)

type returns =
  | Value of {
      statuses : (int * string option) list;
          (** each status it may answer, and when, where the route says *)
      schema : Wiretype.Schema.t;
      examples : string list;
    }
  | Html  (** a page *)
  | Text
  | Empty of (int * string option) list  (** no body, with one of these *)
  | Response
  | Events of (string * data) list  (** each event's name and its data *)
  | Socket of { subprotocol : string option; client : data; server : data }
      (** a WebSocket: what each side sends *)

and data = Json_data of Wiretype.Schema.t | Text_data | Binary_data

type body =
  | Json_body of {
      schema : Wiretype.Schema.t;
      examples : string list;
      required : bool;
          (** an empty body, which [Spindle.json] reads as [{}], is refused *)
    }
  | Form_body of { fields : Wiretype.Schema.t; files : Dep.file list }
      (** a form: an object of its fields, each its codec's, and a repeated one
          a list of them; and its files, which only a multipart body holds *)
  | Parts_body  (** a body read a part at a time *)
  | Raw_body  (** read as it arrived, so an empty one is read too *)

type located = In_path | In_query | In_header | In_cookie

(** A default as the JSON its schema reads. *)
type default =
  | Bare of string  (** a number or a boolean, as its codec prints it *)
  | Quoted of string  (** anything else, a string *)

type parameter = {
  name : string;
  located : located;
  required : bool;
  schema : Wiretype.Schema.t;
  default : default option;
}
(** An input the route reads beside its body: its path's, a query parameter, a
    header, a cookie. A credential is none, since it is its scheme. *)

type route = {
  info : Route.info;
      (** the first's, where several routes are one operation: they share its
          method and its pattern *)
  operation_id : string;  (** [post_orders_order_id_items] *)
  summary : string option;
  doc : string option;
  tags : string list;
  parameters : parameter list;  (** its path's first, then what it reads *)
  credentials : Dep.credential list;
  anonymous : bool;  (** whether a caller with no credential is answered *)
  codes : Refusal.Code.t list;
      (** what it may refuse with, the framework's included, each once *)
  returns : returns;
  body : body option;
}
(** One operation: a route, or the routes that share a method and a pattern --
    told apart by a parameter's type ({!Path.Next_route}) -- which OpenAPI gives
    one operation and zod one key. It reads what any of them reads, a parameter
    required only where every one requires it and of any of their schemas, and
    answers what any of them answers. *)

type t = {
  routes : route list;
  components : (string * Wiretype.Schema.t) list;
  codes : Refusal.Code.t list;
      (** every code any route may refuse with, the framework's included, each
          once *)
  loose : string list;
  errors : string list;
}

val of_app : App.t -> t

val of_shape : Codec.shape -> Wiretype.Schema.t
(** A route input's codec: a path parameter, a query parameter, a header, a
    cookie. *)
