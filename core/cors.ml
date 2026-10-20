include Cors_repr

let policy ~credentials ?(allow_headers = [ "authorization"; "content-type" ])
    ?(expose = []) ?(max_age_s = 600) ?(routes = fun _ -> true) origins =
  {
    origins;
    credentials;
    headers = List.map String.lowercase_ascii allow_headers;
    expose;
    max_age_s;
    routes;
  }

let origins ?(credentials = false) ?allow_headers ?expose ?max_age_s ?routes
    named =
  policy ~credentials ?allow_headers ?expose ?max_age_s ?routes (Origins named)

(* No credentials: the Fetch standard allows none beside [*]. *)
let any ?allow_headers ?expose ?max_age_s ?routes () =
  policy ~credentials:false ?allow_headers ?expose ?max_age_s ?routes Any
