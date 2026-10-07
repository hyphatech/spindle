(** A response as it goes out for one request: the status, every header, and
    what follows them.

    One function decides it, and both the server and {!Test.call} use it, so a
    test sees the head the wire gets. The two differ only in [Connection], which
    belongs to the connection and not to the response, and which the server
    alone writes -- but for a takeover's, which is the protocol's. *)

type body =
  | Nothing  (** a [HEAD], a [204] or a [304] *)
  | Bytes of string
  | Chunks of Response.stream  (** written chunked as it happens *)
  | Counted of int * Response.stream
      (** written as it happens, of the length it said, with [Content-Length] *)
  | Until_close of Response.stream
      (** written as it happens, and ended by closing the connection: a stream
          to an HTTP/1.0 client, which has no chunked coding *)
  | Connection of (Response.connection -> unit)
      (** a takeover: the connection, after the head *)

type t = {
  status : Spindle_http.Status.t;
  headers : (string * string) list;
  body : body;
  closing : bool;  (** the answer asked to be its connection's last *)
  refused : Refusal.t option;
      (** the refusal it answers with: the handler's, or the one this made of an
          answer it would not write *)
  gzip : int option;
      (** a stream the writer encodes with gzip, at this level, as it sends *)
}

val render : ?gzip:int -> Request.t -> Response.t -> t
(** Every 2xx, 3xx and 4xx is dated from the request's clock. Four responses are
    never written as they stand, and become {!Refusal.internal} with the reason
    in the log: one with a header name that is not a token, or a value holding
    CR, LF or NUL, which would let whoever chose it write headers -- or a whole
    response -- of their own; one that sets a field only the server writes,
    which frames the answer or governs its connection; one whose status is not a
    final one, 200 to 599; and a takeover to a protocol the request did not
    offer in [Upgrade] with [Connection: upgrade], or to an HTTP/1.0 client.

    With [gzip], an answer the app chose to compress ({!App.answered}) is
    written with [Content-Encoding: gzip] and its entity tag marked with the
    coding: a buffered body encoded here, and a stream by its writer. *)
