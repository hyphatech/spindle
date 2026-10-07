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
  | Json_body of { schema : Wiretype.Schema.t; examples : string list }
  | Form_body of { fields : Wiretype.Schema.t; files : Dep.file list }
      (** a form: an object of its fields, each its codec's, and a repeated one
          a list of them; and its files, which only a multipart body holds *)
  | Parts_body  (** a body read a part at a time *)
  | Raw_body

type route = {
  info : Route.info;
  operation_id : string;  (** [post_orders_order_id_items] *)
  returns : returns;
  body : body option;
}

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

val framework_codes : Route.info -> Refusal.Code.t list
(** The framework's own codes a route may answer, from what it reads: [invalid]
    where it reads typed inputs, the body's where it reads one, [cross_origin]
    for a method that changes something, and [busy] and [internal] anywhere. *)
