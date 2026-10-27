module Trace = Spindle_http.Trace

let src = Logs.Src.create "spindle.access" ~doc:"Who was refused what"

module L = (val Logs.src_log src : Logs.LOG)

type 'p principal = { caller : 'p Dep.t; id : 'p -> string }

let principal ~id caller = { caller = Dep_repr.mark Caller caller; id }
let caller p = p.caller

type decision = Allow | Deny of string

type ('p, 'a, 'r) policy = {
  name : string;
  principal : 'p principal;
  action : 'a -> string;
  decide : 'p -> 'a -> 'r -> decision;
}

let policy name principal ~action decide = { name; principal; action; decide }
let decide p = p.decide

type ('p, 'a, 'r) resource = { policy : ('p, 'a, 'r) policy; load : 'r Dep.t }

let resource policy load = { policy; load }

let forbidden =
  Refusal.Code.make "forbidden" ~status:`Forbidden
    ~doc:"The caller may not do this."

let refused = Refusal.make forbidden "You may not do that."

(* The reason goes to the log and the span, never to the client, whose answer
   is [refusal] alone. *)
let judge (c : Dep_repr.context) p ~refusal who action thing =
  let fields =
    [
      ("spindle.access.policy", `String p.name);
      ("spindle.access.action", `String (p.action action));
      ("spindle.access.subject", `String (p.principal.id who));
    ]
  in
  let span = Trace.current () in
  match p.decide who action thing with
  | Allow ->
      Trace.add span (("spindle.access.decision", `String "allow") :: fields);
      Ok thing
  | Deny reason ->
      Trace.add span (("spindle.access.decision", `String "deny") :: fields);
      let meth = Spindle_http.Meth.to_string (Request.meth c.request) in
      L.warn (fun m ->
          m "%s %s: %s: %s denied to %s: %s" meth (Request.path c.request)
            p.name (p.action action) (p.principal.id who) reason
            ~tags:
              (Log.tags
                 (fields
                 @ [
                     ("spindle.access.reason", `String reason);
                     ("http.request.method", `String meth);
                     ("url.path", `String (Request.path c.request));
                     ("http.route", `String c.outgoing.pattern);
                   ])));
      Error refusal

(* A dependency of its own identity, listed after [d], answering [f] of what
   [d] answered, in whichever stage [d] answers. *)
let after d ~codes ~access f =
  Dep_repr.make ~inside:d.Dep_repr.listed ~codes ~access:[ access ]
    ~opaque:d.opaque ~binds:d.binds (fun c ->
      match Dep_repr.exec d c with
      | Now v -> Now (Result.bind v (f c))
      | Later k -> Later (fun body -> Result.bind (k body) (f c)))

(* The caller first, so nobody signed in is a 401 before anything is looked
   up. *)
let can ?(deny_as = Refusal.not_found) action r =
  let p = r.policy in
  after
    (Dep.both p.principal.caller r.load)
    ~codes:[ deny_as.code ]
    ~access:(Checked { policy = p.name; action = Some (p.action action) })
    (fun c (who, thing) -> judge c p ~refusal:deny_as who action thing)

let require p action =
  after p.principal.caller ~codes:[ forbidden ]
    ~access:(Checked { policy = p.name; action = Some (p.action action) })
    (fun c who -> judge c p ~refusal:refused who action ())

let check p =
  after p.principal.caller ~codes:[ forbidden ]
    ~access:(Checked { policy = p.name; action = None })
    (fun c who ->
      Ok (fun action thing -> judge c p ~refusal:refused who action thing))

let public = Route_repr.public
