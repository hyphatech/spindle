(* A CORS policy, made by [Cors.make] and applied by [App]. *)

module Meth = Spindle_http.Meth

type origins = Origins of string list | Any

type t = {
  origins : origins;
  credentials : bool;
  headers : string list;  (** lower-cased, as they are compared *)
  expose : string list;
  max_age_s : int;
  routes : Route_repr.info -> bool;
}

let covers t info = t.routes info

let allows t origin =
  match t.origins with
  | Any -> true
  | Origins named -> List.exists (String.equal origin) named

(* Under [Any], only without a cookie: a form another site posts is never
   preflighted and would ride a session. *)
let trusts t ~origin ~cookie =
  match t.origins with
  | Origins named -> List.exists (String.equal origin) named
  | Any -> not cookie

(* [*] only without credentials, beside which a browser reads only its own
   origin, named. *)
let allow_origin t origin =
  match t.origins with
  | Any when not t.credentials -> "*"
  | Any | Origins _ -> origin

let vary_origin = ("vary", "Origin")

let preflight t ~origin ~allow ~requested =
  let asked =
    match requested with
    | None -> []
    | Some v -> List.map String.lowercase_ascii (Spindle_http.Field.elements v)
  in
  let granted = List.filter (fun h -> List.mem h t.headers) asked in
  vary_origin
  :: ("vary", "Access-Control-Request-Method, Access-Control-Request-Headers")
  ::
  (if not (allows t origin) then []
   else
     [
       ("access-control-allow-origin", allow_origin t origin);
       ( "access-control-allow-methods",
         String.concat ", " (List.map Meth.to_string allow) );
       ("access-control-max-age", string_of_int t.max_age_s);
     ]
     @ (match granted with
       | [] -> []
       | _ :: _ ->
           [ ("access-control-allow-headers", String.concat ", " granted) ])
     @
     if t.credentials then [ ("access-control-allow-credentials", "true") ]
     else [])

let answer_headers t ~origin =
  vary_origin
  ::
  (match origin with
  | Some o when allows t o ->
      ("access-control-allow-origin", allow_origin t o)
      :: ((if t.credentials then
             [ ("access-control-allow-credentials", "true") ]
           else [])
         @
         match t.expose with
         | [] -> []
         | names ->
             [ ("access-control-expose-headers", String.concat ", " names) ])
  | Some _ | None -> [])
