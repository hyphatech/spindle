include Dep_repr

let of_request ?needs ?(refuses = []) f =
  make ?needs ~codes:refuses ~opaque:(Option.is_none needs) (fun c ->
      Now (f c.request))

(* A dependency that refuses a type declares it, so its route's document
   says so. *)
let of_body ?content_type ?(refuses = []) ~need f =
  let codes =
    match content_type with
    | Some _ -> refuses @ [ Refusal.Code.unsupported_media_type ]
    | None -> refuses
  in
  make ~codes ~needs:[ Body need ] (fun c ->
      match (content_type, Request.header c.request "content-type") with
      | Some accepts, Some named when not (accepts named) ->
          Now (Error Refusal.unsupported_media_type)
      | (Some _ | None), (Some _ | None) ->
          Later
            (fun held ->
              match Body_repr.whole held with
              | Ok s -> f s
              | Error e -> Error (Body_repr.refusal e)))

(* Nothing of its own to run, so nothing to share. *)
let return v =
  {
    key = None;
    listed = [];
    opaque = false;
    binds = false;
    compute = (fun _ -> Now (Ok v));
  }

let refuse e = make ~codes:[ e.Refusal.code ] (fun _ -> Now (Error e))

(* Listed after [d] and running it through [exec], so [d]'s answer is still
   shared with its other uses. *)
let derived_from ?needs ?codes ?credentials ?opaque ?binds d compute =
  make ~inside:d.listed ?needs ?codes ?credentials
    ~opaque:(Option.value opaque ~default:d.opaque)
    ~binds:(Option.value binds ~default:d.binds)
    compute

let credential ~scheme ?doc d =
  derived_from ~credentials:[ { scheme; doc; reads = needs d } ] d (exec d)

let uncached d =
  { d with key = Option.map (fun k -> { k with cached = false }) d.key }

let problem ~at ~code message =
  Refusal.invalid [ { Refusal.at; code; message } ]

let map f d =
  derived_from d (fun c ->
      match exec d c with
      | Now v -> Now (Result.map f v)
      | Later k -> Later (fun body -> Result.map f (k body)))

let join ?(refuses = []) d =
  derived_from ~codes:refuses d (fun c ->
      match exec d c with
      | Now v -> Now (Result.join v)
      | Later k -> Later (fun body -> Result.join (k body)))

(* Input problems are collected, so a request hears all of them at once; any
   other refusal ends it. *)
let is_problems (r : Refusal.t) =
  Refusal.Code.equal r.code Refusal.Code.invalid
  && match r.problems with [] -> false | _ :: _ -> true

let same_problem (p : Refusal.problem) (q : Refusal.problem) =
  String.equal p.at q.at && String.equal p.code q.code
  && String.equal p.message q.message

(* An input read twice reports one problem. *)
let merge_refusals (a : Refusal.t) (b : Refusal.t) =
  if is_problems a && is_problems b then
    Refusal.invalid
      (a.problems
      @ List.filter
          (fun p -> not (List.exists (same_problem p) a.problems))
          b.problems)
  else if is_problems a then b
  else a

(* A problem on the left waits for the right, which may add its own. *)
let pair_results a b =
  match (a, b) with
  | Ok x, Ok y -> Ok (x, y)
  | Error e, Ok _ | Ok _, Error e -> Error e
  | Error ea, Error eb -> Error (merge_refusals ea eb)

(* A first-stage refusal wins, so no body is read for nothing. A pair runs
   nothing of its own, so it has no identity; each side keeps its own. *)
let both a b =
  {
    key = None;
    listed = a.listed @ b.listed;
    opaque = a.opaque || b.opaque;
    binds = a.binds || b.binds;
    compute =
      (fun c ->
        match exec a c with
        | Now (Error ea) when not (is_problems ea) -> Now (Error ea)
        | Now (Error ea) -> (
            match exec b c with
            | Now (Error eb) -> Now (Error (merge_refusals ea eb))
            | Now (Ok _) | Later _ -> Now (Error ea))
        | Now (Ok x) -> (
            match exec b c with
            | Now v -> Now (Result.map (fun y -> (x, y)) v)
            | Later kb ->
                Later (fun body -> Result.map (fun y -> (x, y)) (kb body)))
        | Later ka -> (
            match exec b c with
            | Now (Error e) -> Now (Error e)
            | Now (Ok y) ->
                Later (fun body -> Result.map (fun x -> (x, y)) (ka body))
            | Later kb ->
                Later
                  (fun body ->
                    match ka body with
                    | Error e when not (is_problems e) -> Error e
                    | a -> pair_results a (kb body))));
  }

(* What [f] reads is unknown until [d] answers, so the result is opaque. It
   runs in the first stage when [d] needs no body. *)
let bind d f =
  derived_from ~opaque:true ~binds:true d (fun c ->
      match exec d c with
      | Now (Error e) -> Now (Error e)
      | Now (Ok x) -> exec (f x) c
      | Later k ->
          Later
            (fun body ->
              match k body with
              | Error e -> Error e
              | Ok x -> (
                  match exec (f x) c with Now v -> v | Later k -> k body)))

let opaque d = d.opaque
