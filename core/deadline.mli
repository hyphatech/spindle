(** How long a connection may keep the server waiting: one deadline for the
    whole connection, and one sweep per domain that looks at every deadline of
    that domain's connections once a tick -- a deadline and its sweep are on the
    same domain, always.

    Every read of the connection, and every flush of an answer to it, runs
    against it, and moving it is a write to a field, not a timer: arming it for
    a head, a body or an answer, and the bytes that go moving it on, cost
    nothing but the write. Once it passes -- which the sweep sees within a tick
    -- the wait on it ends, and so does every wait until it is armed again, for
    the answer that says so, which is a wait of its own. *)

type t

type sweep
(** What looks at every deadline made from it. *)

val sweep : mono_clock:_ Eio.Time.Mono.t -> tick:float -> sweep
(** [sweep ~mono_clock ~tick] looks every [tick] seconds, once {!watch} runs it:
    a deadline passes up to [tick] late. *)

val watch : sweep -> 'a
(** Runs the sweep, for as long as the fiber it is given lasts. *)

val run : sweep -> (t -> 'a) -> 'a
(** [run sweep f] gives [f] a deadline, armed for nothing, and the sweep looks
    at it for as long as [f] runs. *)

val reading : t -> _ Eio.Flow.source -> Eio.Flow.source_ty Eio.Resource.t
(** The flow, read against the deadline: a read still waiting when it passes
    ends as the end of the input, and so does every read until it is armed
    again. Each byte read is {!progress}. *)

val arm : ?per_byte:float -> t -> float -> unit
(** [arm t s] has the deadline [s] seconds from now, and every byte of progress
    after it moves it later by [per_byte] seconds (none): a rate to keep up. *)

val arm_since_last : t -> float -> unit
(** [arm_since_last t s] has the deadline [s] seconds from now, and [s] from
    every byte of progress after it: a bound on a lack of progress, not a rate.
*)

val remaining : t -> float option
(** How long until it passes, in seconds, as it now stands -- none when it is
    armed for nothing; past it, less than zero. *)

val clear : t -> unit
(** Nothing is waited for against it: a wait now lasts as long as it takes. *)

val progress : t -> int -> unit
(** [n] bytes went, and the deadline moves as it was armed to. *)

val wait : t -> (unit -> 'a) -> 'a option
(** [wait t f] is [Some (f ())], or [None] when the deadline passes first -- or
    had already. *)

val passed : t -> bool
(** Whether it passed since it was last armed, so a wait that ended can be told
    from a peer that went. *)
