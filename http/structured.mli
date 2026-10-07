(** Structured Fields, as RFC 9651 defines them for the fields built on it: an
    item, a list or a dictionary, each value with parameters.

    {[
    Structured.dictionary "a=1, b;q=5, c=(x \"y\")"
    = Ok
        [
          ("a", Item (Integer 1, []));
          ("b", Item (Boolean true, [ ("q", Integer 5) ]));
          ("c", Inner ([ (Token "x", []); (String "y", []) ], []));
        ]
    ]}

    A field defines which of the three it is, so the caller says which it reads.
    A field given on several lines is read from its lines joined with [", "]
    (RFC 9651 §4.2). *)

type bare =
  | Integer of int  (** fifteen digits at most, signed *)
  | Decimal of int
      (** thousandths: RFC 9651 bounds a decimal to three fractional digits, so
          [1.5] is [1500] and every decimal is exact *)
  | String of string  (** printable ASCII *)
  | Token of string
  | Bytes of string  (** the bytes, their base64 undone *)
  | Boolean of bool
  | Date of int  (** seconds since 1970-01-01T00:00:00Z *)
  | Display of string  (** UTF-8, which a String cannot hold *)

type parameters = (string * bare) list
(** In order, each key once: a key given twice keeps its first place and its
    last value, as §4.2.3.2 has it. *)

type item = bare * parameters

type member =
  | Item of item
  | Inner of item list * parameters  (** an inner list, and its parameters *)

type dictionary = (string * member) list
(** In order, each key once, as {!parameters}. *)

val item : string -> (item, string) result
val list : string -> (member list, string) result
val dictionary : string -> (dictionary, string) result

val item_to_string : item -> (string, string) result
(** An item as §4.1 writes it, or [Error] where it holds what no field can: an
    integer past fifteen digits, a decimal past twelve, a string with a
    character outside printable ASCII, a key or token that is not one, or a key
    given twice among one value's parameters or a dictionary's members.
    {!val-item} reads it back as itself. *)

val list_to_string : member list -> (string, string) result
val dictionary_to_string : dictionary -> (string, string) result
