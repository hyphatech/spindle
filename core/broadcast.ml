(* Each queue is an [Eio.Stream], safe across domains. The lock is held while
   queues are added to, which never waits, and never while writing to a
   client; holding it across the adds stops two publishers both passing the
   capacity check and spending the slot kept for a dropped subscriber's
   [None]. *)

type ('tag, 'event) t = {
  depth : int;
  lock : Eio.Mutex.t;
  subscriptions : (string, ('tag, 'event) subscription list) Hashtbl.t;
      (** by topic; a list, since a publish walks it whole *)
}

and ('tag, 'event) subscription = {
  hub : ('tag, 'event) t;
  tag : 'tag;
  topic : string;
  queue : 'event option Eio.Stream.t;
  mutable alive : bool; [@atomic]
  mutable slow : bool; [@atomic]
}

let create ?(depth = 16) () =
  if depth < 1 then
    invalid_arg (Printf.sprintf "Spindle.Broadcast.create: ~depth:%d" depth);
  { depth; lock = Eio.Mutex.create (); subscriptions = Hashtbl.create 16 }

(* [use_ro]: nothing here raises, and a lock [use_rw] poisons on a raise.
   Protected, because a release often runs in a fiber already cancelled,
   where waiting for a lock another domain holds raises at once and leaves
   the subscriber behind; the wait is short, since the lock is never held
   across one. *)
let locked t f = Eio.Cancel.protect (fun () -> Eio.Mutex.use_ro t.lock f)

let subscriptions_of t topic =
  Option.value (Hashtbl.find_opt t.subscriptions topic) ~default:[]

(* Under the lock: out of the table first, so nothing publishes to it again,
   then told, into the slot the capacity rule reserved. *)
let drop_subscription t s =
  if s.alive then begin
    s.alive <- false;
    (match List.filter (fun x -> x != s) (subscriptions_of t s.topic) with
    | [] -> Hashtbl.remove t.subscriptions s.topic
    | rest -> Hashtbl.replace t.subscriptions s.topic rest);
    Eio.Stream.add s.queue None
  end

let unsubscribe t s = locked t (fun () -> drop_subscription t s)

(* The queue holds one more than the depth, so there is always room for the
   [None] that tells the writing fiber it has been dropped. *)
let subscribe t ~topic tag f =
  let s =
    {
      hub = t;
      tag;
      topic;
      queue = Eio.Stream.create (t.depth + 1);
      alive = true;
      slow = false;
    }
  in
  locked t (fun () ->
      Hashtbl.replace t.subscriptions topic (s :: subscriptions_of t topic));
  Fun.protect ~finally:(fun () -> unsubscribe t s) (fun () -> f s)

(* Once told it is over, asking again is told again, never left waiting. *)
let next ?until s =
  if (not s.alive) && Eio.Stream.is_empty s.queue then None
  else
    match until with
    | None -> Eio.Stream.take s.queue
    | Some p when Eio.Promise.is_resolved p -> None
    | Some p ->
        Eio.Fiber.first
          (fun () -> Eio.Stream.take s.queue)
          (fun () ->
            Eio.Promise.await p;
            None)

(* One watcher a subscription rather than [next ~until]'s race an event,
   which costs a loop about three times as much; it drops the subscriber as
   a slow one is dropped, so the loop ends at its next wait and nothing it
   runs is cancelled. *)
let forward ?until s send =
  let rec loop () =
    match next s with
    | Some event -> Result.bind (send event) loop
    | None -> Ok ()
  in
  match until with
  | None -> loop ()
  | Some p when Eio.Promise.is_resolved p -> Ok ()
  | Some p ->
      Eio.Switch.run @@ fun sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Promise.await p;
          unsubscribe s.hub s;
          `Stop_daemon);
      loop ()

(* Every topic out of the table at once, then every subscriber told: one
   pass, where dropping each from its topic's list would walk it again. *)
let close t =
  locked t (fun () ->
      let subscriptions =
        Hashtbl.fold
          (fun _ subs acc -> List.rev_append subs acc)
          t.subscriptions []
      in
      Hashtbl.reset t.subscriptions;
      List.iter
        (fun s ->
          if s.alive then (
            s.alive <- false;
            Eio.Stream.add s.queue None))
        subscriptions)

let publish t ~topic event =
  locked t (fun () ->
      List.iter
        (fun s ->
          if Eio.Stream.length s.queue >= t.depth then begin
            s.slow <- true;
            drop_subscription t s
          end
          else Eio.Stream.add s.queue (Some event))
        (subscriptions_of t topic))

let topics t =
  locked t (fun () ->
      Hashtbl.fold (fun topic _ acc -> topic :: acc) t.subscriptions [])

let subscribers t ~topic =
  locked t (fun () -> List.map (fun s -> s.tag) (subscriptions_of t topic))

let dropped s = s.slow
