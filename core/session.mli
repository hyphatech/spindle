(** Sessions kept on the server: a visit's data in a store, and a cookie that
    holds only its id.

    {[
    let session =
      Spindle.Session.create
        ~store:(Spindle.Dep.return (Spindle.Session.memory ()))
        ~idle:Mtime.Span.(14 * day)
        ~absolute:Mtime.Span.(90 * day)
        visit_json

    let me =
      Spindle.get
        Path.(s "me")
        Returns.text
        (let+ session = session in
         let* visit = Spindle.Session.get session in
         Ok (match visit with Some v -> v.user | None -> "nobody"))
    ]}

    {b A session's failure is a refusal}: a store that fails, or data its
    description cannot write, is {!Refusal.internal}, why in the log, since a
    handler can do nothing with either but answer [500]. So each call goes on
    with [let*] beside the handler's own.

    {b A session is a dependency}, read as every input is: {!create} makes it,
    and a route that reads it is handed the session its request's cookie names,
    with nothing asked of the store yet. Every use of it in one request is the
    same session, so what a {!put} wrote a later {!get} reads. Its cookie is set
    and its limits are timed by the session itself, from the request's answer
    and its clock.

    {b The cookie holds an id, and the store its digest.} An id is 128 bits from
    the operating system's generator, so there is nothing to sign and nothing to
    guess; the store keys a SHA-256 digest of it, so a copy of the store signs
    nobody in. The cookie is [HttpOnly; SameSite=Lax], and [Secure] is the
    framework's, as every cookie's is.

    {b A session ends on the server.} {!destroy} deletes it, so a copy of its
    cookie signs nobody in afterwards, and {!rotate} at sign-in moves it to a
    new id and deletes the old, so an id somebody planted before sign-in signs
    them into nothing. Two limits end it by themselves: [idle] since it was last
    used, moved on by a {!get} that finds more than a tenth of it spent -- so a
    busy session is not a write per request -- and [absolute] since it began.
    Past either, {!get} answers [None] and deletes it.

    {b A session nobody returns to is swept by the sessions themselves}: the
    first request that reads one ten minutes after the last sweep deletes up to
    a batch of the expired, and the next request another batch while a sweep
    finds a full one, so a store never grows with visits that ended and a
    request never waits on more than a batch. The ten minutes are the app's own
    and counted on its monotonic clock, as a {!Rate} limit's are; a failed sweep
    is a warning in the log, and the request goes on.

    {b The store is read as a route reads anything the application holds}: a
    dependency -- [Dep.return] of one made at the top level, a
    {!Dep.of_resource} the server is handed, or one read through another, as
    [Spindle_postgres.Session.store] is through the pool's -- so a session, and
    the routes that read it, are values made before it exists. *)

(** {1 Stores} *)

type entry = {
  data : string;  (** the data, as its description writes it *)
  created : Ptime.t;
  seen : Ptime.t;
  expires : Ptime.t;  (** when either limit ends it *)
}
(** A session as a store holds it, by its id's digest. *)

type store = {
  find : string -> (entry option, string) result;
  save : string -> entry -> (unit, string) result;  (** insert or replace *)
  delete : string -> (unit, string) result;
  sweep : now:Ptime.t -> limit:int -> (int, string) result;
      (** delete up to [limit] entries expired by [now], the soonest expired
          first: how many went *)
}
(** Where sessions are kept: anything that can hold these, a table in a database
    ([Spindle_postgres.Session.store]) as much as memory. An [Error] is the
    store's failure, in words for the log. *)

val memory : unit -> store
(** A table behind a lock, for one process: its sessions end with it. A sweep
    costs the entries it deletes, never the table. *)

(** {1 Sessions} *)

type 'a t
(** The session a request has, if any, and the store it is kept in. *)

val create :
  ?cookie:string ->
  store:store Dep.t ->
  idle:Mtime.Span.t ->
  absolute:Mtime.Span.t ->
  'a Wiretype.t ->
  'a t Dep.t
(** A session of data ['a], kept in the store [store] reads for each request,
    under a cookie named [cookie] ([session]), whose [Max-Age] is [absolute] in
    whole seconds, rounded up. Its cookie is a credential, in the document of
    every route that reads it. Raises as {!Cookie.val-named} does for a name no
    cookie can have. *)

val get : 'a t -> ('a option, Refusal.t) result
(** The session's data, if its cookie names one that is kept and within both
    limits; one that is not, or whose data no longer reads as ['a], is deleted
    and [None]. The store is asked once a request. *)

val put : 'a t -> 'a -> (unit, Refusal.t) result
(** The session's data, replaced -- or a new session holding it, and its cookie,
    where there was none. Its limits run on. *)

val rotate : 'a t -> (unit, Refusal.t) result
(** The session moved to a new id, its data kept and the old id deleted, its
    limits begun again: at sign-in, beside the {!put} of who signed in, in
    either order. Nothing, where there is no session. *)

val destroy : 'a t -> (unit, Refusal.t) result
(** The session deleted from the store, and its cookie cleared: sign-out.
    Nothing, where there is no session. *)
