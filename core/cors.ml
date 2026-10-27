include Cors_repr

let policy ~credentials ?(allow_headers = [ "authorization"; "content-type" ])
    ?(expose = []) ?(max_age_s = 600) origins =
  Some
    {
      origins;
      credentials;
      headers = List.map String.lowercase_ascii allow_headers;
      expose;
      max_age_s;
    }

let origins ?(credentials = false) ?allow_headers ?expose ?max_age_s named =
  policy ~credentials ?allow_headers ?expose ?max_age_s (Origins named)

(* No credentials: the Fetch standard allows none beside [*]. *)
let any ?allow_headers ?expose ?max_age_s () =
  policy ~credentials:false ?allow_headers ?expose ?max_age_s Any

let none = None
