(** A form's fields, typed: [Spindle.Form.required "email" Wiretype.string].

    A field is an input as a query parameter is, read by its wiretype
    description, and a problem with one is {!Refusal.invalid} at [form.<name>],
    reported with every other problem of the request at once. The body is read
    once, as a form, however many fields a route reads ({!Dep}'s sharing):
    [application/x-www-form-urlencoded], what a browser posts from a form with
    no file, and what a body with no [Content-Type] is read as, or
    [multipart/form-data], what it posts from one with a file (below). A body of
    any other [Content-Type] is {!Refusal.unsupported_media_type} before it is
    read, and a field whose text is not UTF-8 is a problem at its name. The body
    is held whole, up to the server's [max_body]. A field sent more than once is
    read by its first value, as a query parameter is ({!Query}), and {!list}
    reads every one.

    A form is a body as {!Spindle.json} is: a route that reads a field beside
    another body, or beside {!Spindle.body_stream}, is refused when the app is
    made.

    {b Forgery is the origin check's.} A browser posts a form to another site
    without asking, which is why such a request is {!Refusal.cross_origin}
    before any route sees it ({!App.make}); a form is read under that and
    nothing else, so there is no token to put in one.

    {[
    let email = Spindle.Form.required "email" Wiretype.string
    let remember = Spindle.Form.checked "remember"

    let sign_up_route =
      Spindle.post
        Path.(s "sign-up")
        (Spindle.Returns.json account_json)
        (let+ email = email and+ remember = remember in
         sign_up ~email ~remember)
    ]} *)

val optional : string -> 'a Wiretype.t -> 'a option Dep.t
(** The first value given, if any. *)

val required : string -> 'a Wiretype.t -> 'a Dep.t

val list : string -> 'a Wiretype.t -> 'a list Dep.t
(** Every value given, in order: a group of checkboxes of one name. *)

val checked : string -> bool Dep.t
(** Whether the field was sent at all: a checkbox that is not ticked is not
    sent, whatever its value would have been. *)

(** {1 Files}

    A form with a file in it is [multipart/form-data], read whole as the rest of
    a form is. A part with a [filename] is a file, and a file input left empty
    -- which a browser sends as a part with an empty filename and nothing in it
    -- is no file. A file is read as a field is, by its name:
    [Spindle.Form.File.optional "avatar"]. *)

module File : sig
  type t = {
    filename : string option;
        (** text a person chose, and never a path: a route that saves a file
            names it itself *)
    content_type : Spindle_http.Media_type.t;
        (** [text/plain] where the part names none (RFC 7578 §4.4) *)
    content : string;
  }

  val optional : string -> t option Dep.t
  (** The first file given, if any. *)

  val required : string -> t Dep.t

  val list : string -> t list Dep.t
  (** Every file of one name, in order: a [multiple] file input. *)
end
