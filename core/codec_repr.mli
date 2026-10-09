(** A codec as the framework holds it: what {!Codec} is, underneath, and the one
    thing only the framework reads of one, whether its value is a list. Each
    value {!Codec} exports is documented there. *)

type shape =
  | String
  | Format of Wiretype.Shape.format
  | Integer
  | Number
  | Boolean
  | Enum of string list

type 'a t = {
  parse : string -> 'a option;
  print : 'a -> string;
  expects : string;
  shape : shape;
  kind : string option;
  list : bool;
      (** a list, as RFC 9110 §5.6.1 writes one: a header sent on several lines
          is read whole, its lines joined by [", "], where any other value sent
          twice is refused *)
}
