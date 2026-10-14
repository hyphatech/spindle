type shape =
  | String
  | Format of Wiretype.Shape.format
  | Integer
  | Number
  | Boolean
  | Enum of string list

type 'a t = {
  parse : string -> ('a, string) result;
      (** [Error] is the sentence a client is told *)
  print : 'a -> string;
  expects : string;
  shape : shape;
  kind : string option;
  list : bool;
}
