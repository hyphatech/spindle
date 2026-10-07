(** Where a body ends: decided from its message's head, then read off the
    connection a piece at a time.

    Whatever this cannot delimit exactly is refused rather than guessed at,
    because a body that ends in the wrong place leaves its remainder on the
    connection, to be read as the next request -- which, behind a proxy that
    shares its connections, is somebody else's request. *)

type t =
  | No_body
  | Fixed of int
  | Chunked
  | Until_close
      (** to the end of the connection: a response's alone, and it leaves
          nothing after it to read *)

val of_request : Head.Request.t -> (t, Status.t * string) result
(** How the request's body is framed. [Error (status, detail)] for what RFC 9112
    forbids: [Transfer-Encoding] beside [Content-Length], a [Content-Length]
    that is not one non-negative number, and a [Transfer-Encoding] that does not
    end in [chunked] or names it twice ([400]), or one that asks for a coding
    this server does not decode ([501]). [Transfer-Encoding] is a list, so an
    empty element in it is nothing. A chunked body's lines end in CRLF and
    nothing else. Never [Until_close]: a request that could end only with its
    connection could never be answered. *)

val of_response : request_meth:Meth.t -> Head.Response.t -> (t, string) result
(** How a response's body is framed, by RFC 9112 §6.3 in its order: [No_body]
    after [HEAD], and for a 1xx, a 204 or a 304, whatever the fields say, and
    for a 2xx to [CONNECT], after which the connection is a tunnel; then
    [Chunked] for [Transfer-Encoding: chunked], a length where [Content-Length]
    is one, and [Until_close] where neither is sent.

    [Error] says, for a log, what cannot be read: both fields, which is a
    response built to be read two ways; a length {!of_request} would refuse;
    [chunked] twice; or any other coding, which nothing here decodes and a
    server may not send unasked (RFC 9112 §7.4) -- the RFC reads one that does
    not end in [chunked] to the close, and what it reads there is the coding's
    bytes, not the body. *)

type reader

val reader : t -> Eio.Buf_read.t -> max_trailer:int -> reader
(** A reader for one body on this connection; a chunked body's trailer is
    bounded by [max_trailer] bytes. The end of input is the end of an
    [Until_close] body, and breaks any other. A read waits as long as the flow
    under the buffer does, so how long a peer may take is the flow's to bound --
    a server's deadline, a client's call -- and a flow that gives up by ending
    breaks the body like any other end. *)

val read :
  reader ->
  max:int ->
  reserve:(int -> bool) ->
  (string, [ `Too_large | `Busy | `Broken of string ]) result
(** The whole body. [`Too_large] past [max] bytes -- at once for a declared
    length, without reading any of it -- and a chunked body's extensions, which
    carry nothing of it, count toward them. [reserve n] is asked before [n] more
    bytes are held, as they arrive -- a declared length's too, since a length is
    only a claim until its bytes come -- and [`Busy] is its [false]. *)

val read_some :
  reader ->
  max:int ->
  reserve:(int -> bool) ->
  ( [ `Data of string | `End ],
    [ `Too_large | `Busy | `Broken of string ] )
  result
(** The next piece of the body as it arrived, at most 64 KiB, or its end: a body
    read as it comes. [max] and [reserve] are {!read}'s, over the whole body --
    [`Too_large] once what has been read passes [max], and at once for a
    declared length past it -- and [reserve n] is asked for each piece as it is
    read. *)

val discard : reader -> limit:int -> bool
(** Reads and drops what is left, at most [limit] bytes of it, a chunked body's
    extensions included: [true] when the body was read to its end, so the
    connection can carry another request. A declared remainder past [limit] is
    not read at all. *)
