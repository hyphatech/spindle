(* A year: the longest RFC 2616 let Expires promise, which caches still take
   as forever; immutable (RFC 8246) spares even a reload's revalidation. *)
let kept_a_year = "public, max-age=31536000, immutable"

(* A failure is never kept: a 404 for an asset not yet deployed would
   outlive the deployment. *)
let succeeded status =
  let code = Spindle_http.Status.to_int status in
  (code >= 200 && code < 300) || code = 304

(* A path's own URL and a slash, so [/assetsheet] is never under
   [/assets]; a path takes no argument, so it always has one. *)
let prefix_of path =
  match Path.url path [] with
  | Ok "/" -> Some "/"
  | Ok url -> Some (url ^ "/")
  | Error _ -> None

let forever ~under =
  let under = List.filter_map prefix_of under in
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
