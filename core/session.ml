module L = (val Logs.src_log Log.http : Logs.LOG)

type entry = {
  data : string;
  created : Ptime.t;
  seen : Ptime.t;
  expires : Ptime.t;
}

type store = {
  find : string -> (entry option, string) result;
  save : string -> entry -> (unit, string) result;
  delete : string -> (unit, string) result;
  sweep : now:Ptime.t -> limit:int -> (int, string) result;
}

(* 128 bits, which nobody guesses. *)
let id_bytes = 16

(* Ordered by when each expires, so a sweep takes the soonest from the front
   and costs what it deletes, never a walk of the table under its lock. *)
module By_expiry = Set.Make (struct
  type t = Ptime.t * string

  let compare (a, x) (b, y) =
    match Ptime.compare a b with 0 -> String.compare x y | c -> c
end)

(* Reached from any domain, so behind a lock held for the table alone. *)
let memory () =
  let table = Hashtbl.create 64
  and by_expiry = ref By_expiry.empty
  and lock = Eio.Mutex.create () in
  let locked f = Eio.Mutex.use_rw ~protect:false lock f in
  let remove digest =
    match Hashtbl.find_opt table digest with
    | Some e ->
        Hashtbl.remove table digest;
        by_expiry := By_expiry.remove (e.expires, digest) !by_expiry
    | None -> ()
  in
  {
    find = (fun digest -> Ok (locked (fun () -> Hashtbl.find_opt table digest)));
    save =
      (fun digest e ->
        Ok
          (locked (fun () ->
               remove digest;
               Hashtbl.replace table digest e;
               by_expiry := By_expiry.add (e.expires, digest) !by_expiry)));
    delete = (fun digest -> Ok (locked (fun () -> remove digest)));
    sweep =
      (fun ~now ~limit ->
        Ok
          (locked (fun () ->
               let rec go n =
                 match By_expiry.min_elt_opt !by_expiry with
                 | Some (expires, digest)
                   when n < limit && not (Ptime.is_later expires ~than:now) ->
                     remove digest;
                     go (n + 1)
                 | Some _ | None -> n
               in
               go 0)));
  }

type 'a sessions = {
  named : string Cookie.named;
  idle : Mtime.Span.t;
  absolute : Mtime.Span.t;
  description : 'a Wiretype.t;
}

type 'a current =
  | Unread
  | Absent
  | Present of { digest : string; data : 'a; created : Ptime.t }

type 'a t = {
  sessions : 'a sessions;
  store : store;
  set_cookie : Cookie.t -> unit;
  now : Ptime.t;
  id : string option;  (** what the request's cookie held *)
  mutable current : 'a current;
      (** what the store said, kept so it is asked once a request *)
}

(* A handler can do nothing with a store's failure, or with data its own
   description cannot write, but answer 500: each is that refusal, why
   in its detail for the log. *)
let failed detail = Refusal.internal ~detail

(* The store knows a session by its id's digest, never by its id. *)
let digest_of_id id = Digestif.SHA256.(to_hex (digest_string id))
let of_store r = Result.map_error (fun m -> failed ("a session store: " ^ m)) r
let ( let* ) = Result.bind

(* How long an expired session may outlive its end before a sweep deletes
   it: nothing reads one, so this bounds the store's size, never what a
   visitor sees. *)
let sweep_every = Mtime.Span.(10 * min)

(* What one request deletes at most, so the request that sweeps waits on a
   batch and never on a backlog. *)
let sweep_batch = 500

(* One request sweeps, whichever domain it is on: the one that moves the
   next sweep on from the instant it read. A full batch leaves the next
   sweep due at once, so a backlog is drained a batch a request. *)
let sweep_if_due store ~next ~mono ~now =
  let due = Atomic.get next in
  if
    (not (Mtime.is_later due ~than:mono))
    && Atomic.compare_and_set next due
         (Option.value
            (Mtime.add_span mono sweep_every)
            ~default:Mtime.max_stamp)
  then
    match store.sweep ~now ~limit:sweep_batch with
    | Ok n when n >= sweep_batch -> Atomic.set next mono
    | Ok _ -> ()
    | Error m -> L.warn (fun f -> f "a session sweep failed: %s" m)

let request_now = Dep.of_request ~needs:[] (fun r -> Ok (Request.now r))

let create ?(cookie = "session") ~store ~idle ~absolute description =
  let sessions =
    { named = Cookie.named cookie Wiretype.string; idle; absolute; description }
  in
  let id =
    Dep.credential
      ~scheme:(Cookie.Named.name sessions.named)
      ~doc:"A session the server keeps, by the id its cookie holds."
      (Input.optional Input.cookie
         (Cookie.Named.name sessions.named)
         Wiretype.string)
  in
  let next_sweep =
    Dep_repr.kept ~make:(fun () -> Atomic.make Mtime.min_stamp)
  in
  Dep.map
    (fun (((id, store), (set_cookie, now)), (next, mono)) ->
      sweep_if_due store ~next ~mono ~now;
      { sessions; store; set_cookie; now; id; current = Unread })
    (Dep.both
       (Dep.both (Dep.both id store) (Dep.both Outgoing.set_cookie request_now))
       next_sweep)

let expiry t ~created =
  let idle_ends = Spindle_http.Instant.add t.now t.sessions.idle
  and absolute_ends = Spindle_http.Instant.add created t.sessions.absolute in
  if Ptime.is_later idle_ends ~than:absolute_ends then absolute_ends
  else idle_ends

let save t ~digest ~created data =
  match Wiretype.encode t.sessions.description data with
  | Error m ->
      Error (failed ("a session's data: " ^ Wiretype.Unwritable.to_string m))
  | Ok text ->
      let* () =
        of_store
          (t.store.save digest
             { data = text; created; seen = t.now; expires = expiry t ~created })
      in
      t.current <- Present { digest; data; created };
      Ok ()

(* A new id, saved and set as the cookie: the session's limits begin. *)
let save_new t data =
  let id = Cookie_repr.encode (Mirage_crypto_rng_unix.getrandom id_bytes) in
  let* () = save t ~digest:(digest_of_id id) ~created:t.now data in
  t.set_cookie
    (Cookie.make
       ~max_age_s:(Cookie_repr.whole_seconds t.sessions.absolute)
       t.sessions.named id);
  Ok ()

let ended t digest =
  let* () = of_store (t.store.delete digest) in
  t.current <- Absent;
  Ok Absent

let read t =
  match (t.current, t.id) with
  | (Absent | Present _), _ -> Ok t.current
  | Unread, None ->
      t.current <- Absent;
      Ok Absent
  | Unread, Some id -> (
      let digest = digest_of_id id in
      let* found = of_store (t.store.find digest) in
      match found with
      | None ->
          t.current <- Absent;
          Ok Absent
      | Some e when not (Ptime.is_later e.expires ~than:t.now) -> ended t digest
      | Some e -> (
          match Wiretype.decode t.sessions.description e.data with
          | Error _ ->
              L.debug (fun m ->
                  m "a session's data no longer reads, so it is ended");
              ended t digest
          | Ok data ->
              (* Moved on after a tenth of the idle limit, so a busy session
                 is not a write per request. *)
              let tenth =
                Mtime.Span.of_uint64_ns
                  (Int64.unsigned_div
                     (Mtime.Span.to_uint64_ns t.sessions.idle)
                     10L)
              in
              let* () =
                if
                  Ptime.is_later t.now
                    ~than:(Spindle_http.Instant.add e.seen tenth)
                then save t ~digest ~created:e.created data
                else (
                  t.current <- Present { digest; data; created = e.created };
                  Ok ())
              in
              Ok t.current))

let get t =
  let* current = read t in
  match current with
  | Present p -> Ok (Some p.data)
  | Absent | Unread -> Ok None

let put t data =
  let* current = read t in
  match current with
  | Present p -> save t ~digest:p.digest ~created:p.created data
  | Absent | Unread -> save_new t data

let rotate t =
  let* current = read t in
  match current with
  | Present p ->
      let* () = of_store (t.store.delete p.digest) in
      save_new t p.data
  | Absent | Unread -> Ok ()

let destroy t =
  let* current = read t in
  match current with
  | Present p ->
      let* _ = ended t p.digest in
      t.set_cookie (Cookie.clear t.sessions.named);
      Ok ()
  | Absent | Unread -> Ok ()
