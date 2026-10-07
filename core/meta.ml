(* Each key is a constructor of an extensible variant, so a value comes back
   only under its own key, with its type, and no cast. *)
type binding = ..

type 'a key = {
  id : int;
  inject : 'a -> binding;
  project : binding -> 'a option;
}

(* Tells keys apart. Atomic, since a library loaded late may make a key on
   any domain. *)
let next_id = Atomic.make 0

let key (type a) () : a key =
  let module M = struct
    type binding += K of a
  end in
  {
    id = Atomic.fetch_and_add next_id 1 + 1;
    inject = (fun v -> M.K v);
    project = (function M.K v -> Some v | _ -> None);
  }

type t = (int * binding) list

let empty = []

let add k v t =
  if List.exists (fun (id, _) -> id = k.id) t then
    List.map (fun (id, b) -> if id = k.id then (id, k.inject v) else (id, b)) t
  else t @ [ (k.id, k.inject v) ]

let find k t =
  Option.bind
    (List.find_opt (fun (id, _) -> id = k.id) t)
    (fun (_, b) -> k.project b)

let summary = key ()
let doc = key ()
let tags = key ()
let access : Logs.level key = key ()
