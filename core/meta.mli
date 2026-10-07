(** What a route says about itself beside what it does: a summary, a
    description, tags -- and whatever a package adds, under keys of its own.

    OCaml keeps no docstrings at run time, so what a document says of a route is
    written beside it, as values:

    {[
    let item =
      Spindle.post ~summary:"Add an item" ~tags:[ "orders" ] path answer inputs

    (* a package's own *)
    let rate : int Spindle.Meta.key = Spindle.Meta.key ()

    let limited =
      Spindle.get ~meta:Spindle.Meta.(empty |> add rate 10) path answer inputs
    ]}

    A key is typed, so what is found under it is what was put there. *)

type 'a key

val key : unit -> 'a key
(** A new key, told apart from every other. *)

type t

val empty : t

val add : 'a key -> 'a -> t -> t
(** Replaces what was there. *)

val find : 'a key -> t -> 'a option

(** {1 The framework's own} *)

val summary : string key
(** A line: what the route does. *)

val doc : string key
(** As much as the route needs said about it. *)

val tags : string list key
(** Groups a document may file the route under. *)

val access : Logs.level key
(** The level of the route's line in the access log: [Info] unless set. A route
    something asks every few seconds -- a probe -- sets [Debug], so its lines
    are there when asked for and do not bury what happened. *)
