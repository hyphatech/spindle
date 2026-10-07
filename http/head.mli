(** A message's head, read off a connection: its start line and its fields, and
    nothing a parser could read two ways.

    A head RFC 9112 forbids is refused rather than repaired, because two readers
    that repair it differently -- this one and a proxy in front of it --
    disagree about where one message ends and the next begins. The one repair
    made is the one the RFC requires of a user agent, in {!Response}. *)

type version = Http_1_0 | Http_1_1

(** Why a request's head was not read. *)
type error =
  | Closed  (** the peer went, or its connection failed, before a whole head *)
  | Refused of Status.t * string
      (** a head that cannot be read: the status it owes, and what was wrong,
          for a log *)

(** A request's head, as a server reads it. *)
module Request : sig
  (** The request-target's form (RFC 9112 §3.2). *)
  type form =
    | Origin  (** [/path?query], the ordinary one *)
    | Absolute  (** [http://host/path], as a proxy is sent it *)
    | Authority  (** [host:port], CONNECT's *)
    | Asterisk  (** [*], a server-wide OPTIONS *)

  type t = {
    meth : Meth.t;
    target : string;  (** the request-target as it arrived *)
    form : form;
    version : version;
        (** [HTTP/1.1] for any later HTTP/1 minor version, which is answered as
            the highest this server speaks *)
    headers : (string * string) list;
        (** in the order sent, names as sent, values trimmed *)
    host : string option;
        (** the host the request is for, as it was sent: an absolute-form or
            authority-form target's authority, otherwise the [Host] field --
            [None] when neither names one *)
  }

  val read : max:int -> Eio.Buf_read.t -> (t, error) result
  (** The next head. Empty lines before it are skipped, as RFC 9112 asks. A
      request line is a method token, a target of visible ASCII and a version,
      each one space apart: another major version than [HTTP/1] is [505], and a
      request line past [max] bytes [414]. The target's form must be one its
      method may use, and an absolute one's authority a host with no userinfo. A
      field is what {!Field.parse} reads; a bare CR and a field section past
      [max] bytes -- [431] -- are refused, and a line may end in a bare LF,
      which RFC 9112 lets a recipient accept.

      An HTTP/1.1 request needs exactly one [Host], and no request may carry two
      or one that is not a host ([400], RFC 9112 §3.2) -- an absolute-form
      target included, whose authority is then the host all the same. A host is
      RFC 3986's: a name, or in brackets an IPv6 address or an IPvFuture, and
      never any other run of characters there; [CONNECT]'s target is a host and
      a port, both there. *)

  val keep_alive : t -> bool
  (** Whether the client asked to keep the connection: HTTP/1.1 unless
      [Connection: close], and HTTP/1.0 only with [Connection: keep-alive] --
      and never after an HTTP/1.0 request carrying [Transfer-Encoding], which
      HTTP/1.0 does not have, so whoever framed it cannot be trusted to have
      ended it where it ends (RFC 9112 §6.1). *)
end

(** A response's head, as a client reads it.

    Two readers over one field grammar rather than one with flags, because a
    client and a server are owed different things by the same bytes: RFC 9112
    §5.2 has a user agent {e join} an obsolete fold that a server must refuse,
    and a response may end where its connection does. *)
module Response : sig
  type t = {
    version : version;
        (** [HTTP/1.1] for any later HTTP/1 minor version, as for a request *)
    status : Status.t;
    reason : string;  (** as sent, and nothing should act on it *)
    headers : (string * string) list;
        (** in the order sent, names as sent, values trimmed, a folded line
            joined onto the field before it *)
  }

  val read :
    max:int -> Eio.Buf_read.t -> (t, [ `Closed | `Malformed of string ]) result
  (** The next head. [`Closed] is the server going, or its connection failing,
      before a byte of one arrived -- which is what a kept connection the server
      gave up on looks like -- and [`Malformed] anything else that is not a
      head, one cut short included, in words for a log.

      A status line is a version, a space, a code of three digits from 100 to
      599, and the reason after a space; the space may be missing, since nothing
      turns on the reason. Another major version than [HTTP/1] is malformed. An
      empty line before the status line is not skipped, as a server skips one
      before a request: to a client it is the last response ending somewhere its
      framing did not say. A field is what {!Field.parse} reads, but for an
      obsolete fold, joined by {!Field.unfold}; a bare CR and a head past [max]
      bytes are malformed, and a line may end in a bare LF.

      A 1xx is a head of its own, with no body, and the final response follows
      it. *)

  val keep_alive : t -> bool
  (** Whether the server will keep the connection, on the same terms as
      {!Request.keep_alive}. Whether the body leaves it where the next response
      begins is {!Framing}'s: a body delimited by the connection closing ends
      with it. *)
end
