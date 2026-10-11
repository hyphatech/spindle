(* Keys are set from any domain, so the table is behind a lock. A wake-up
   sleeps on the domain that set it; superseding it resolves a promise,
   which reaches any domain, and the generation tells a wake-up it was
   superseded as it woke. *)
type entry = { generation : int; resolve_stopped : unit Eio.Promise.u }

type t = {
  background : Background.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  slack : Mtime.Span.t;
  lock : Eio.Mutex.t;
  current : (string, entry) Hashtbl.t;
  mutable last_generation : int;  (** under [lock] *)
}

let create ?(slack = Mtime.Span.(50 * ms)) ~background ~mono_clock:clock () =
  {
    background;
    clock :> Eio.Time.Mono.ty Eio.Resource.t;
    slack;
    lock = Eio.Mutex.create ();
    current = Hashtbl.create 16;
    last_generation = 0;
  }

(* [use_ro]: nothing here raises, and a lock [use_rw] poisons on a raise. *)
let locked t f = Eio.Mutex.use_ro t.lock f

let stop_wake_up (e : entry) =
  ignore (Eio.Promise.try_resolve e.resolve_stopped () : bool)

let remove_entry t ~key =
  match Hashtbl.find_opt t.current key with
  | Some e ->
      stop_wake_up e;
      Hashtbl.remove t.current key
  | None -> ()

let cancel t ~key = locked t (fun () -> remove_entry t ~key)

let set t ~key ~after ~what f =
  let stopped, resolve_stopped = Eio.Promise.create () in
  let generation =
    locked t (fun () ->
        remove_entry t ~key;
        t.last_generation <- t.last_generation + 1;
        Hashtbl.replace t.current key
          { generation = t.last_generation; resolve_stopped };
        t.last_generation)
  in
  Background.fork t.background ~what (fun () ->
      let woke =
        Eio.Fiber.first
          (fun () ->
            Eio.Time.Mono.sleep_span t.clock (Mtime.Span.add after t.slack);
            true)
          (fun () ->
            Eio.Promise.await stopped;
            false)
      in
      (* Removed before [f] runs, so [f] may set its own key again. *)
      let due =
        locked t (fun () ->
            match Hashtbl.find_opt t.current key with
            | Some e when woke && e.generation = generation ->
                Hashtbl.remove t.current key;
                true
            | Some _ | None -> false)
      in
      if due then f ())
