module L = (val Logs.src_log Log.http : Logs.LOG)

type entry = {
  data : string;
  created_ms : int;
  seen_ms : int;
  expires_ms : int;
}

type store = {
  find : string -> (entry option, string) result;
  save : string -> entry -> (unit, string) result;
  delete : string -> (unit, string) result;
  sweep : now:int -> (int, string) result;
}

(* 128 bits, which nobody guesses. *)
let id_bytes = 16

(* Reached from any domain, so behind a lock held for the table alone. *)
let memory () =
  let table = Hashtbl.create 64 and lock = Eio.Mutex.create () in
  let locked f = Eio.Mutex.use_rw ~protect:false lock f in
  {
    find = (fun digest -> Ok (locked (fun () -> Hashtbl.find_opt table digest)));
    save =
      (fun digest e -> Ok (locked (fun () -> Hashtbl.replace table digest e)));
    delete = (fun digest -> Ok (locked (fun () -> Hashtbl.remove table digest)));
    sweep =
      (fun ~now ->
        Ok
          (locked (fun () ->
               let expired =
                 Hashtbl.fold
                   (fun k e acc ->
                     if e.expires_ms <= now then k :: acc else acc)
                   table []
               in
               List.iter (Hashtbl.remove table) expired;
               List.length expired)));
  }

type 'a t = {
  store : store;
  named : string Cookie.named;
  idle_ms : int;
  absolute_ms : int;
  absolute_s : int;
  description : 'a Wiretype.t;
}

let create ?(cookie = "session") ~store ~idle_s ~absolute_s description =
  {
    store;
    named = Cookie.named cookie Codec.string;
    idle_ms = idle_s * 1000;
    absolute_ms = absolute_s * 1000;
    absolute_s;
    description;
  }

type id = string

let cookie t =
  Dep.credential
    ~scheme:(Cookie.Named.name t.named)
    ~doc:"A session the server keeps, by the id its cookie holds."
    (Input.optional Input.cookie (Cookie.Named.name t.named) Codec.string)

type 'a session = { digest : string; data : 'a; created_ms : int }

let data s = s.data

type error = Store of string | Unencodable of Wiretype.Unwritable.t

let refusal = function
  | Store detail -> Refusal.internal ~detail:("a session store: " ^ detail)
  | Unencodable e ->
      Refusal.internal
        ~detail:("a session's data: " ^ Wiretype.Unwritable.to_string e)

(* The store knows a session by its id's digest, never by its id. *)
let digest_of_id id = Digestif.SHA256.(to_hex (digest_string id))
let of_store r = Result.map_error (fun m -> Store m) r
let ( let* ) = Result.bind
let expiry_ms t ~created ~now = min (now + t.idle_ms) (created + t.absolute_ms)

let save t ~digest ~created ~now data =
  match Wiretype.encode t.description data with
  | Error m -> Error (Unencodable m)
  | Ok text ->
      let* () =
        of_store
          (t.store.save digest
             {
               data = text;
               created_ms = created;
               seen_ms = now;
               expires_ms = expiry_ms t ~created ~now;
             })
      in
      Ok { digest; data; created_ms = created }

let find t id ~now =
  match id with
  | None -> Ok None
  | Some id -> (
      let digest = digest_of_id id in
      let* found = of_store (t.store.find digest) in
      match found with
      | None -> Ok None
      | Some e when e.expires_ms <= now ->
          let* () = of_store (t.store.delete digest) in
          Ok None
      | Some e -> (
          match Wiretype.decode t.description e.data with
          | Error _ ->
              L.debug (fun m ->
                  m "a session's data no longer reads, so it is ended");
              let* () = of_store (t.store.delete digest) in
              Ok None
          | Ok data ->
              (* Renewed after a tenth of the idle limit, so a busy session
                 is not a write per request. *)
              if now - e.seen_ms > t.idle_ms / 10 then
                Result.map Option.some
                  (save t ~digest ~created:e.created_ms ~now data)
              else Ok (Some { digest; data; created_ms = e.created_ms })))

let start t ~set_cookie ~now data =
  let id = Cookie_repr.encode (Mirage_crypto_rng_unix.getrandom id_bytes) in
  let* session = save t ~digest:(digest_of_id id) ~created:now ~now data in
  set_cookie (Cookie.make ~max_age:t.absolute_s t.named id);
  Ok session

let renew t old ~set_cookie ~now data =
  let* () = of_store (t.store.delete old.digest) in
  start t ~set_cookie ~now data

let update t s ~now data =
  save t ~digest:s.digest ~created:s.created_ms ~now data

let close t s ~set_cookie =
  let* () = of_store (t.store.delete s.digest) in
  set_cookie (Cookie.clear t.named);
  Ok ()

let sweep t ~now = of_store (t.store.sweep ~now)
