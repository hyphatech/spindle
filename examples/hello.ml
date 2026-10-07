(* The smallest application: one endpoint, answering at /.

   Every example keeps three things apart -- the endpoints, what each
   answers; the routes, which URL reaches which endpoint; and the server --
   so each reads on its own, and an endpoint is plain OCaml a test can call
   without a server. *)

(* --8<-- [start:app] *)
let good_morning = Ok "Good morning, world!"

let routes =
  [
    Spindle.get Spindle.Path.root Spindle.Returns.text
      (Spindle.Dep.return good_morning);
  ]

let () = Eio_main.run @@ fun env -> Spindle.serve env routes
(* --8<-- [end:app] *)
