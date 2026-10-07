module L = (val Logs.src_log Log.http : Logs.LOG)

type check = { name : string; run : unit -> (unit, string) result }

let check name run = { name; run }

let not_ready =
  Refusal.Code.make "not_ready" ~status:`Service_unavailable
    ~doc:"Something the server needs to serve did not answer."

(* Probed every few seconds, so its access line is at debug. *)
let debug_access = Meta.(empty |> add access Logs.Debug)

(* A raise is a bug, answered as one; only a returned error is the check
   failing. *)
let failure_of c =
  match c.run () with Ok () -> None | Error why -> Some (c.name, why)

let ready_now checks =
  match List.filter_map Fun.id (Eio.Fiber.List.map failure_of checks) with
  | [] -> Ok "ok"
  | failed ->
      (* Logged as a warning, not as the refusal's detail, which a 5xx logs as
         an error: a database down is degraded, not a bug. *)
      List.iter
        (fun (n, why) -> L.warn (fun m -> m "not ready: %s: %s" n why))
        failed;
      Error
        (Refusal.make not_ready
           (Printf.sprintf "Not ready: %s."
              (String.concat ", " (List.map fst failed))))

let routes ?(live = Path.s "livez") ?(ready = Path.s "readyz") checks =
  [
    Route_repr.get ~summary:"Whether the process answers" ~meta:debug_access
      live Returns.text (Dep.return (Ok "ok"));
    Route_repr.get ~summary:"Whether the server can serve" ~meta:debug_access
      ~refuses:[ not_ready ] ready Returns.text
      (Dep.map (fun () -> ready_now checks) (Dep.return ()));
  ]
