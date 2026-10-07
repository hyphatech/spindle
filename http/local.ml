(* A fiber binding rather than domain-local storage, so a fiber that outlives
   the server never finds its finished switch. The domain is kept beside it
   because Eio forks onto no other domain's switch. *)

let key : (Domain.id * Eio.Switch.t) Eio.Fiber.key = Eio.Fiber.create_key ()

let switch () =
  match Eio.Fiber.get key with
  | Some (d, sw) when Int.equal (d :> int) (Domain.self () :> int) -> Some sw
  | Some _ | None -> None
  | exception Effect.Unhandled _ -> None

let within ~sw f = Eio.Fiber.with_binding key (Domain.self (), sw) f
