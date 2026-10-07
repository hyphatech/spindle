(* The probes: /livez answers for as long as the process can, and /readyz
   only while every check passes. The check here is the application's own:
   a file named [maintenance] takes the server out of service, so a load
   balancer sends it nobody until the file is gone.

     curl -i localhost:8080/readyz    200
     touch maintenance
     curl -i localhost:8080/readyz    503 not_ready
     curl -i localhost:8080/livez     200 all along *)

let hello = Ok "Hello."

let routes =
  [
    Spindle.get Spindle.Path.root Spindle.Returns.text
      (Spindle.Dep.return hello);
  ]

let in_service =
  Spindle.Health.check "maintenance" (fun () ->
      if Sys.file_exists "maintenance" then
        Error "the maintenance file is there"
      else Ok ())

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle.serve env (routes @ Spindle.Health.routes [ in_service ])
