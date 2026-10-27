(* The suites test everything but who may call a route, which test_access
   tests, so each route that says nobody may call it is made public here:
   Spindle.App.make and Spindle.Test.app as they are, but for that. A route
   that reads a caller or a check keeps it. *)

let declared r =
  match (Spindle.Route.info r).access with
  | [] -> Spindle.Access.public r
  | _ :: _ -> r

let make ?middleware ?refuses ?not_found ?cors ?compress ?check_origin
    ?trusted_origins ?trailing_slash routes =
  Spindle.App.make ?middleware ?refuses ?not_found ?cors ?compress ?check_origin
    ?trusted_origins ?trailing_slash (List.map declared routes)

let app ?resources ?mono_clock ?middleware ?refuses ?not_found ?cors ?compress
    ?check_origin ?trusted_origins ?trailing_slash ?keys routes =
  Spindle.Test.app ?resources ?mono_clock ?middleware ?refuses ?not_found ?cors
    ?compress ?check_origin ?trusted_origins ?trailing_slash ?keys
    (List.map declared routes)
