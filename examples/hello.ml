(* The smallest application: one route, answering at /.

   Every example keeps three things apart -- the handlers, what each
   answers; the routes, which URL reaches which handler; and the server --
   so each reads on its own, and a handler is plain OCaml a test can call
   without a server.

   A route says who may call it, or the server does not start: this one
   anybody, as a page anyone may read. *)

let good_morning = Ok "Good morning, world!"

let routes =
  List.map Spindle.Access.public
    [
      Spindle.get Spindle.Path.root Spindle.Returns.text
        (Spindle.Dep.return good_morning);
    ]

let () = Eio_main.run @@ fun env -> Spindle.serve env routes
