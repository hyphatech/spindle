type handler = Request.t -> Response.t
type t = handler -> handler

let headers extra handler req =
  let response = handler req in
  let already_set name =
    List.exists
      (fun (k, _) -> String.equal (String.lowercase_ascii k) name)
      (Response.headers response)
  in
  Response.add_headers
    (List.filter
       (fun (k, _) -> not (already_set (String.lowercase_ascii k)))
       extra)
    response
