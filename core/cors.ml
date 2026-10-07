include Cors_repr

let make ?(credentials = false) ?(headers = [ "authorization"; "content-type" ])
    ?(expose = []) ?(max_age_s = 600) ?(routes = fun _ -> true) origins =
  match (origins, credentials) with
  | Any, true ->
      invalid_arg
        "Spindle.Cors.make: Any origin beside credentials, which the Fetch \
         standard does not allow"
  | (Any | Origins _), (true | false) ->
      {
        origins;
        credentials;
        headers = List.map String.lowercase_ascii headers;
        expose;
        max_age_s;
        routes;
      }
