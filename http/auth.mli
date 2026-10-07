(** Authentication, as RFC 9110 §11 writes it: the credentials a request carries
    in [Authorization] or [Proxy-Authorization], and the challenges a [401] or a
    [407] names in [WWW-Authenticate] or [Proxy-Authenticate].

    {[
    Auth.credentials "Bearer mF_9.B5f-4.1JqM"
    = Ok { scheme = "bearer"; value = Token68 "mF_9.B5f-4.1JqM" }
    ]} *)

type value =
  | Token68 of string  (** one opaque token: a bearer token, Basic's base64 *)
  | Params of (string * string) list
      (** named parameters, each name lower-cased; none for a scheme alone *)

type t = {
  scheme : string;  (** lower-cased: RFC 9110 §11.1 compares it without case *)
  value : value;
}

val credentials : string -> (t, string) result
(** The credentials in an [Authorization] value; a parameter given twice is an
    [Error] (RFC 9110 §11.2), in words for a log, and never quoting the value,
    which is a secret. *)

val challenges : string -> (t list, string) result
(** Every challenge in a [WWW-Authenticate] value, in order: a parameter belongs
    to the challenge before it, so a comma inside a quoted string, or between
    one challenge's parameters, does not start another; a challenge naming a
    parameter twice is an [Error]. *)

val to_string : t -> (string, string) result
(** The scheme, then its token or its parameters, a value a quoted string where
    it is no token: what a server writes as a challenge and a client as
    credentials. {!credentials} and {!challenges} read it back as itself, and
    what they would not -- a scheme or a name that is no token or is not
    lower-cased, a parameter twice, a token that is no [token68] -- is an
    [Error], which quotes nothing of the value. *)
