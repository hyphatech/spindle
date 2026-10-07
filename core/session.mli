(** Sessions kept on the server: a visit's data in a store, and a cookie that
    holds only its id.

    {[
    let sessions =
      Spindle.Session.create ~store:(Spindle.Session.memory ())
        ~idle_s:(14 * 86400) ~absolute_s:(90 * 86400) visit_json

    (let+ session = Spindle.Session.cookie sessions
     and+ set_cookie = Spindle.set_cookie and+ now = Spindle.now in
     match Spindle.Session.find sessions session ~now with ...)
    ]}

    {b The cookie holds an id, and the store its digest.} An id is 128 bits from
    the operating system's generator, so there is nothing to sign and nothing to
    guess; the store keys a SHA-256 digest of it, so a copy of the store signs
    nobody in. The cookie is [HttpOnly; SameSite=Lax], and [Secure] is the
    framework's, as every cookie's is.

    {b A session ends on the server.} {!close} deletes it, so a copy of its
    cookie signs nobody in afterwards, and {!renew} at sign-in gives it a new id
    and deletes the old, so an id somebody planted before sign-in signs them
    into nothing. Two limits end it by themselves: [idle_s] since it was last
    used, moved on by a {!val-find} that finds more than a tenth of it spent --
    so a busy session is not a write per request -- and [absolute_s] since it
    began, never moved. Past either, {!val-find} answers [None] and deletes it.

    {b Reading the store is the handler's}: {!cookie} hands over what the
    request carries, as every input does, and {!val-find} is called where the
    handler decides. A flash message is a value in the session's data. *)

(** {1 Stores} *)

type entry = {
  data : string;  (** the data, as its description writes it *)
  created_ms : int;
  seen_ms : int;
  expires_ms : int;  (** when either limit ends it *)
}
(** A session as a store holds it, by its id's digest. *)

type store = {
  find : string -> (entry option, string) result;
  save : string -> entry -> (unit, string) result;  (** insert or replace *)
  delete : string -> (unit, string) result;
  sweep : now:int -> (int, string) result;
      (** delete every entry expired by [now]: how many went *)
}
(** Where sessions are kept: anything that can hold these, a table in a database
    ([Spindle_postgres.Session.store]) as much as memory. An [Error] is the
    store's failure, in words for the log. *)

val memory : unit -> store
(** A table behind a lock, for one process: its sessions end with it. *)

(** {1 Sessions} *)

type 'a t

val create :
  ?cookie:string ->
  store:store ->
  idle_s:int ->
  absolute_s:int ->
  'a Wiretype.t ->
  'a t
(** A session of data ['a], kept in [store] under a cookie named [cookie]
    ([session]). Raises as {!Cookie.val-named} does for a name no cookie can
    have. *)

type id
(** What a session's cookie carries. *)

val cookie : 'a t -> id option Dep.t
(** The session a request says it has: a credential, read as every input is, and
    nothing the store has been asked about yet. *)

type 'a session
(** A session found, started or renewed. *)

val data : 'a session -> 'a

type error =
  | Store of string  (** the store failed, in words for the log *)
  | Unencodable of Wiretype.Unwritable.t
      (** the data's description could not write it, and where *)

val refusal : error -> Refusal.t
(** {!Refusal.internal}, the detail in the log. *)

val find : 'a t -> id option -> now:int -> ('a session option, error) result
(** The session the id names, if it is kept and within both limits; one that is
    not, or whose data no longer reads as ['a], is deleted and [None]. *)

val start :
  'a t ->
  set_cookie:(Cookie.t -> unit) ->
  now:int ->
  'a ->
  ('a session, error) result
(** A new session of this data, and its cookie: sign-in for a visitor who had
    none. *)

val renew :
  'a t ->
  'a session ->
  set_cookie:(Cookie.t -> unit) ->
  now:int ->
  'a ->
  ('a session, error) result
(** The session under a new id with this data, the old deleted: sign-in for a
    visitor who had one. Its limits begin again, as a new session's do. *)

val update : 'a t -> 'a session -> now:int -> 'a -> ('a session, error) result
(** New data under the same id: for data that changes nothing about who is
    signed in -- a basket, a flash. What does is {!renew}'s. *)

val close :
  'a t -> 'a session -> set_cookie:(Cookie.t -> unit) -> (unit, error) result
(** Deleted from the store, and its cookie cleared. *)

val sweep : 'a t -> now:int -> (int, error) result
(** Every expired session deleted: for an {!Alarm} to run, since one nobody
    returns to is never found. *)
