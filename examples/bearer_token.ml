(* A bearer token, read from the Authorization header and refused with a
   401 when it is missing or is not one: the dependency bearer_auth's routes
   list. *)

open Spindle.Syntax

(* A 401 names how to authenticate, in WWW-Authenticate, so the code carries
   the challenge. *)
let signed_out =
  Spindle.Refusal.Code.make "signed_out" ~status:`Unauthorized
    ~challenge:{|Bearer realm="notes"|} ~doc:"No valid bearer token was sent."

let please_sign_in = Spindle.Refusal.make signed_out "Please sign in."

(* Made of the framework's own header input, read as credentials -- a
   scheme compared without case, so "bearer abc" is a bearer token as
   "Bearer abc" is -- and [join] turns a check that fails into a refusal of
   the request. The header is optional rather than required because a
   missing token is a 401, not a malformed request. [credential] names the
   scheme for the document, which reads the rest: Authorization is HTTP
   authentication, and a 401 means the token is needed. *)
let bearer =
  Spindle.Dep.credential ~scheme:"bearer"
    (Spindle.Dep.join ~refuses:[ signed_out ]
       (let+ credentials =
          Spindle.Header.optional "authorization" Spindle.Codec.credentials
        in
        match credentials with
        | Some { scheme = "bearer"; value = Token68 token } -> Ok token
        | Some _ | None -> Error please_sign_in))
