(** What a handler adds to its answer as dependencies: the cookies and headers
    it sets, for {!Spindle.set_cookie}, {!Spindle.add_header} and whatever else
    in the framework sets one, so each is set the one way. *)

val set_cookie : (Cookie.t -> unit) Dep.t
val add_header : (string * string -> unit) Dep.t
