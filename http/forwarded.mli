(** [Forwarded], as RFC 7239 writes it: each proxy a request passed through,
    what it saw -- who asked it, on which of its interfaces, for which host,
    over which protocol.

    {[
    Forwarded.parse {|for=192.0.2.60;proto=https, for="[2001:db8::1]:47011"|}
    ]}

    Believe it only from a proxy that writes it: a client writes one as easily.
*)

type name =
  | Address of string  (** an IPv4 or IPv6 address, an IPv6 one unbracketed *)
  | Unknown  (** the proxy did not know *)
  | Obfuscated of string  (** a name standing in for one, [_hidden] *)

type port = Port of int | Obfuscated_port of string

type node = { name : name; port : port option }
(** RFC 7239 §6's node: [for] and [by] name one. *)

type element = {
  for_ : node option;  (** who asked this proxy *)
  by : node option;  (** the interface it was asked on *)
  host : string option;  (** the Host it was asked for *)
  proto : string option;  (** the scheme it was asked over, lower-cased *)
  extensions : (string * string) list;
      (** any other parameter, its name lower-cased *)
}

val parse : string -> (element list, string) result
(** Every element, in the order the proxies wrote them, the nearest proxy's
    last. A parameter given twice in one element, a [for] or [by] that is no
    node, or a [proto] that is no scheme, is an [Error]. *)

val to_string : element list -> (string, string) result
(** Each element's parameters, a value quoted where it is no token -- an IPv6
    node always is -- or [Error] for what {!parse} would not read back as
    itself: an empty element, an extension named [for], [by], [host] or [proto]
    or named twice, an address, an obfuscated name or a scheme that is none. *)
