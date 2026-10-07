(* A middleware of the application's own: every request is counted before
   any route answers it, and the answer says how many there have been.

   The count is an [Atomic] and not a [ref]: a request runs on any of the
   domains the server serves on, beside the others, so a [ref] would lose
   increments under load. *)

open Spindle.Syntax

let count = Atomic.make 0

let count_requests handler request =
  Atomic.incr count;
  handler request

let saw () = Ok (Printf.sprintf "Saw %i request(s)!" (Atomic.get count))

let routes =
  [
    (* [let+] over [Dep.return ()] runs [saw] on every request; [Dep.return
       (saw ())] would make the answer once, when the route is. *)
    Spindle.get Spindle.Path.root Spindle.Returns.text
      (let+ () = Spindle.Dep.return () in
       saw ());
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env ~middleware:[ count_requests ] routes
