(* Each queue is an [Eio.Stream], safe across domains. The lock is held while
   queues are added to, which never waits, and never while writing to a
   client; holding it across the adds stops two publishers both passing the
   capacity check and spending the slot kept for a dropped subscriber's
   [None]. *)

type ('tag, 'event) subscription = {
  tag : 'tag;
  topic : string;
  queue : 'event option Eio.Stream.t;
  mutable alive : bool; [@atomic]
}

type ('tag, 'event) t = {
  depth : int;
  lock : Eio.Mutex.t;
  subscriptions : (string, ('tag, 'event) subscription list) Hashtbl.t;
      (** by topic; a list, since a publish walks it whole *)
}

let create ?(depth = 16) () =
  if depth < 1 then
    invalid_arg (Printf.sprintf "Spindle.Broadcast.create: ~depth:%d" depth);
  { depth; lock = Eio.Mutex.create (); subscriptions = Hashtbl.create 16 }

(* [use_ro]: nothing here raises, and a lock [use_rw] poisons on a raise. *)
let locked t f = Eio.Mutex.use_ro t.lock f

let subscriptions_of t topic =
  Option.value (Hashtbl.find_opt t.subscriptions topic) ~default:[]

(* The queue holds one more than the depth, so there is always room for the
   [None] that tells the writing fiber it has been dropped. *)
let subscribe t ~topic tag =
  let s =
    { tag; topic; queue = Eio.Stream.create (t.depth + 1); alive = true }
  in
  locked t (fun () ->
      Hashtbl.replace t.subscriptions topic (s :: subscriptions_of t topic));
  s

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

(* Once told it is over, asking again is told again, never left waiting. *)
let next s =
  if (not s.alive) && Eio.Stream.is_empty s.queue then None
  else Eio.Stream.take s.queue

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
          if Eio.Stream.length s.queue >= t.depth then drop_subscription t s
          else Eio.Stream.add s.queue (Some event))
        (subscriptions_of t topic))

let topics t =
  locked t (fun () ->
      Hashtbl.fold (fun topic _ acc -> topic :: acc) t.subscriptions [])

let subscribers t ~topic =
  locked t (fun () -> List.map (fun s -> s.tag) (subscriptions_of t topic))
