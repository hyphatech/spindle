(* A directory served: public, at the root, so / is its index.html and
   /style.css its stylesheet. The path is the program's working directory's,
   so run it from this one:

     cd examples && dune exec ./static.exe

   The directory is read into memory once, when the server starts -- one
   whose directory cannot be read does not start, and says why -- and every
   request is a lookup among what was there: a file changed afterwards needs
   a restart, and a path that was not there is never a file, whatever it
   spells. *)

(* --8<-- [start:app] *)
let routes = [ Spindle.Static.directory "public" ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
(* --8<-- [end:app] *)
