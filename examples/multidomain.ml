(* A table every request writes: the visits to each page.

   A request runs on any of the server's domains, beside the others, so a
   table they all write is behind a lock -- an [Eio.Mutex], which parks the
   fiber waiting for it rather than its whole domain, held across nothing
   but the table, never across a write to a client or a call to a database.

   A [Hashtbl] with neither a lock nor one domain is not a crash in OCaml 5
   but it is no table either: two domains adding at once lose one of the
   writes, a lookup on one domain sees the other's resize half done and
   finds nothing where something is, and a resize that meets another raises
   from inside the table. None of it shows on a laptop's first try.

   A server that must not lock runs on one domain, [~domains:1], where a
   fiber gives way only at an effect and a table touched between two needs
   nothing: [--one-domain] below. The middleware example keeps a single number,
   which is an [Atomic]; a table is not a number.

     dune exec examples/multidomain.exe
     curl localhost:8080/pages/home
     dune exec examples/multidomain.exe -- --one-domain *)

open Spindle.Syntax

let visits : (string, int) Hashtbl.t = Hashtbl.create 16
let lock = Eio.Mutex.create ()

let visit page =
  let n = 1 + Option.value (Hashtbl.find_opt visits page) ~default:0 in
  Hashtbl.replace visits page n;
  n

let page_name = Spindle.Path.string "page"
let path = Spindle.Path.(s "pages" / page_name)

let locked =
  Spindle.Access.public
  @@ Spindle.get path Spindle.Returns.text
       (let+ page = Spindle.param page_name in
        let n = Eio.Mutex.use_rw ~protect:false lock (fun () -> visit page) in
        Ok (Printf.sprintf "%s: visit number %d\n" page n))

let unlocked =
  Spindle.Access.public
  @@ Spindle.get path Spindle.Returns.text
       (let+ page = Spindle.param page_name in
        Ok (Printf.sprintf "%s: visit number %d\n" page (visit page)))

let () =
  Spindle.Log.setup ();
  let one_domain = Array.exists (String.equal "--one-domain") Sys.argv in
  Eio_main.run @@ fun env ->
  if one_domain then Spindle.serve env ~domains:1 [ unlocked ]
  else Spindle.serve env [ locked ]
