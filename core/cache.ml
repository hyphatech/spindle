let check prefix =
  let n = String.length prefix in
  if n = 0 || prefix.[0] <> '/' || prefix.[n - 1] <> '/' then
    invalid_arg
      (Printf.sprintf
         "Cache.forever: %S is no prefix; one begins and ends with \"/\"" prefix)

(* A year: the longest RFC 2616 let Expires promise, which caches still take
   as forever; immutable (RFC 8246) spares even a reload's revalidation. *)
let kept_a_year = "public, max-age=31536000, immutable"

(* A failure is never kept: a 404 for an asset not yet deployed would
   outlive the deployment. *)
let succeeded status =
  let code = Spindle_http.Status.to_int status in
  (code >= 200 && code < 300) || code = 304

let forever ~under =
  List.iter check under;
  fun handler req ->
    let response = handler req in
    let read = match Request.meth req with `GET | `HEAD -> true | _ -> false
    and path = Request.path req in
    if
      read
      && succeeded (Response.status response)
      && List.exists (fun prefix -> String.starts_with ~prefix path) under
    then Response.with_header ("cache-control", kept_a_year) response
    else response
