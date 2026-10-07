module Local = Spindle_http.Local

let src = Logs.Src.create "spindle.background" ~doc:"Work nobody is waiting for"

module L = (val Logs.src_log src : Logs.LOG)

(* Work from a domain with no switch of Spindle's, carrying its request's
   context, which does not cross a domain on its own. Unbounded, because
   posting must never wait; it is the rare path. *)
type job = { what : string; work : unit -> unit }
type t = { sw : Eio.Switch.t; domain : Domain.id; posted : job Eio.Stream.t }

let fork_logged ~sw ~what f =
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try f () with
      | Eio.Cancel.Cancelled _ as ex -> raise ex
      | ex ->
          let bt = Printexc.get_raw_backtrace () in
          L.err (fun m ->
              m "%s: %s" what (Printexc.to_string ex)
                ~tags:(Log.tags (Log.raised ex bt))));
      `Stop_daemon)

let create ~sw =
  let posted = Eio.Stream.create max_int in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec run_posted () =
        let { what; work } = Eio.Stream.take posted in
        fork_logged ~sw ~what work;
        run_posted ()
      in
      run_posted ());
  { sw; domain = Domain.self (); posted }

let fork t ~what f =
  match Local.switch () with
  | Some sw -> fork_logged ~sw ~what f
  | None when Int.equal (t.domain :> int) (Domain.self () :> int) ->
      fork_logged ~sw:t.sw ~what f
  | None -> Eio.Stream.add t.posted { what; work = Log.carry f }
