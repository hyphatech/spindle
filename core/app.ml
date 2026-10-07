module Status = Spindle_http.Status
module Meth = Spindle_http.Meth
module L = (val Logs.src_log Log.http : Logs.LOG)

type handler = Request.t -> Response.t

(* Beside the response, for the access log and the test client: which route
   answered, and what in the answer nobody declared. *)
type undeclared = Code of Refusal.Code.t | Status of Status.t

type answered = {
  route : string option;
  undeclared : undeclared option;
  access : Logs.level;
  gzip : int option;
}

type trailing_slash = Strict | Redirect

(* The routes compiled by segment. Plain parameters at one position share a
   node, since only what follows tells them apart; a declining parameter has
   its own, with its own parser. *)
type node = {
  mutable ends_here : (Route_repr.t * int) list;
      (** the routes this path ends at, with their listed position *)
  literals : (string, node) Hashtbl.t;
  mutable declining_params : ((string -> bool) * node) list;
      (** in listed order *)
  mutable plain_param : node option;
  mutable rest_routes : (Route_repr.t * int) list;
      (** routes whose rest parameter starts here *)
}

type t = {
  routes : Route_repr.t list;  (** in the order they were listed *)
  table : node;
  methods : Meth.t list;  (** every method some route answers, in order *)
  not_found : handler option;
  middleware : Middleware.t list;
  codes : Refusal.Code.t list;
      (** what the middleware and [not_found] answer *)
  check_origin : bool;
  trusted_origins : string list;
  cors : Cors_repr.t option;
  compress : Compress_repr.t option;
  trailing_slash : trailing_slash;
}

let meth_of (r : Route_repr.t) = r.info.meth
let pattern_of (r : Route_repr.t) = r.info.pattern
let segments_of (r : Route_repr.t) = r.segments
let route_name r = Meth.to_string (meth_of r) ^ " " ^ pattern_of r

let param_names r =
  List.filter_map
    (function
      | Path_repr.Parameter { name; _ } | Path_repr.Rest name -> Some name
      | Path_repr.Literal _ -> None)
    (segments_of r)

(* No position tells them apart: the same literal, two plain parameters, or
   two rests. Anything else is precedence, or listed order between two
   declining parameters. *)
let could_match_alike a b =
  Meth.equal (meth_of a) (meth_of b)
  && List.compare_lengths (segments_of a) (segments_of b) = 0
  && List.for_all2
       (fun x y ->
         match (x, y) with
         | Path_repr.Literal l, Path_repr.Literal m -> String.equal l m
         | ( Path_repr.Parameter { or_not_found = false; _ },
             Path_repr.Parameter { or_not_found = false; _ } )
         | Path_repr.Rest _, Path_repr.Rest _ ->
             true
         | Path_repr.Literal _, (Path_repr.Parameter _ | Path_repr.Rest _)
         | Path_repr.Parameter _, (Path_repr.Literal _ | Path_repr.Rest _)
         | Path_repr.Rest _, (Path_repr.Literal _ | Path_repr.Parameter _)
         | Path_repr.Parameter { or_not_found = true; _ }, Path_repr.Parameter _
         | Path_repr.Parameter _, Path_repr.Parameter { or_not_found = true; _ }
           ->
             false)
       (segments_of a) (segments_of b)

let check_path r =
  let params = param_names r in
  let rec first_duplicate = function
    | [] -> None
    | n :: rest ->
        if List.exists (String.equal n) rest then Some n
        else first_duplicate rest
  in
  (* A rest takes every segment after it, so nothing may follow it. *)
  let rec rest_before_end = function
    | [] | [ _ ] -> None
    | Path_repr.Rest n :: _ :: _ -> Some n
    | (Path_repr.Literal _ | Path_repr.Parameter _) :: more ->
        rest_before_end more
  in
  match
    ( List.find_opt
        (function
          | Path_repr.Literal l -> String.equal l "" || String.contains l '/'
          | Path_repr.Parameter _ | Path_repr.Rest _ -> false)
        (segments_of r),
      first_duplicate params,
      List.find_map
        (function
          | Dep.Path n when not (List.exists (String.equal n) params) -> Some n
          | Dep.Path _ | Dep.Query _ | Dep.Header _ | Dep.Cookie _ | Dep.Field _
          | Dep.File _ | Dep.Body _ | Dep.Custom _ ->
              None)
        (r.info.needs : Dep.need list) )
  with
  | Some (Path_repr.Literal l), _, _ ->
      Error
        (Printf.sprintf "%s has the literal segment %S, which no URL can match"
           (route_name r) l)
  | Some (Path_repr.Parameter _ | Path_repr.Rest _), _, _ | None, None, None
    -> (
      match rest_before_end (segments_of r) with
      | Some n ->
          Error
            (Printf.sprintf
               "%s has the rest of its path, %s, before its end, where nothing \
                after it could be matched"
               (route_name r) n)
      | None -> Ok ())
  | None, Some n, _ ->
      Error (Printf.sprintf "%s names the parameter %s twice" (route_name r) n)
  | None, None, Some n ->
      Error
        (Printf.sprintf
           "%s reads the path parameter %s, which its path does not have"
           (route_name r) n)

(* A form or a stream consumes the body, so it is the only way it is read. *)
let check_body (r : Route_repr.t) =
  let bodies =
    List.filter_map
      (function
        | Dep.Body b -> Some b
        | Dep.Path _ | Dep.Query _ | Dep.Header _ | Dep.Cookie _ | Dep.Field _
        | Dep.File _ | Dep.Custom _ ->
            None)
      r.info.needs
  in
  let consumes_body = function
    | Dep.Stream | Dep.Form | Dep.Multipart -> true
    | Dep.Raw | Dep.Json _ -> false
  in
  if List.exists consumes_body bodies && List.compare_length_with bodies 1 > 0
  then
    Error
      (Printf.sprintf
         "%s reads its body as a form or as it arrives and reads it another \
          way too, where a body is read one way"
         (route_name r))
  else Ok ()

(* Listed statuses are successes, since failing is a refusal, each once. *)
let check_statuses r =
  let statuses =
    match r.Route_repr.info.returns with
    | Returns_repr.Json_response { statuses; _ }
    | Returns_repr.Empty_response statuses ->
        Some (List.map (fun (s, _) -> Status.to_int s) statuses)
    | Returns_repr.Json _ | Html | Text | Empty _ | Response | Events _
    | Websocket _ ->
        None
  in
  match statuses with
  | None -> Ok ()
  | Some [] ->
      Error (Printf.sprintf "%s lists no status to answer" (route_name r))
  | Some statuses -> (
      match List.find_opt (fun s -> s < 200 || s > 299) statuses with
      | Some s ->
          Error
            (Printf.sprintf
               "%s lists %d, which is not a success: failing is a refusal"
               (route_name r) s)
      | None ->
          if
            List.compare_lengths (List.sort_uniq Int.compare statuses) statuses
            < 0
          then Error (Printf.sprintf "%s lists a status twice" (route_name r))
          else Ok ())

let check r =
  let is_websocket =
    match r.Route_repr.info.returns with
    | Returns_repr.Websocket _ -> true
    | Returns_repr.Json _ | Json_response _ | Html | Text | Empty _
    | Empty_response _ | Response | Events _ ->
        false
  in
  if Meth.equal (meth_of r) `HEAD then
    Error
      (Printf.sprintf
         "%s: a HEAD is answered by the GET route, so declare that instead"
         (route_name r))
  else if is_websocket && not (Meth.equal (meth_of r) `GET) then
    Error
      (Printf.sprintf "%s: a WebSocket is opened by a GET (RFC 6455 §4.1)"
         (route_name r))
  else
    Result.bind (check_path r) (fun () ->
        Result.bind (check_body r) (fun () -> check_statuses r))

(* A client branches on a code's name, so a name has one status and one doc
   wherever it is declared. *)
let check_codes ~codes routes =
  let declared =
    List.map (fun c -> ("the framework", c)) Refusal.Code.framework
    @ List.map (fun c -> ("the application", c)) codes
    @ List.concat_map
        (fun (r : Route_repr.t) ->
          List.map (fun c -> (route_name r, c)) r.info.codes)
        routes
  in
  let conflict a b =
    Refusal.Code.equal a b
    && not
         (Status.equal (Refusal.Code.status a) (Refusal.Code.status b)
         && String.equal (Refusal.Code.doc a) (Refusal.Code.doc b)
         && Option.equal String.equal (Refusal.Code.challenge a)
              (Refusal.Code.challenge b))
  in
  (* RFC 9110 §15.5.2: a 401 names its challenge. *)
  let lacks_challenge c =
    Status.equal (Refusal.Code.status c) `Unauthorized
    && Option.is_none (Refusal.Code.challenge c)
  in
  let rec check = function
    | [] -> Ok ()
    | (where, c) :: _ when lacks_challenge c ->
        Error
          (Printf.sprintf
             "the code %s in %s is a 401 with no challenge, which its \
              WWW-Authenticate must name"
             (Refusal.Code.name c) where)
    | (where, c) :: rest -> (
        match List.find_opt (fun (_, d) -> conflict c d) rest with
        | None -> check rest
        | Some (other, d) ->
            Error
              (Printf.sprintf
                 "the code %s means two things: %d (%s) in %s, and %d (%s) in \
                  %s"
                 (Refusal.Code.name c)
                 (Status.to_int (Refusal.Code.status c))
                 (Refusal.Code.doc c) where
                 (Status.to_int (Refusal.Code.status d))
                 (Refusal.Code.doc d) other))
  in
  check declared

let empty_node () =
  {
    ends_here = [];
    literals = Hashtbl.create 4;
    declining_params = [];
    plain_param = None;
    rest_routes = [];
  }

let compile routes =
  let root = empty_node () in
  List.iteri
    (fun i r ->
      let rec insert n = function
        | [] -> n.ends_here <- n.ends_here @ [ (r, i) ]
        | Path_repr.Literal l :: rest ->
            let child =
              match Hashtbl.find_opt n.literals l with
              | Some c -> c
              | None ->
                  let c = empty_node () in
                  Hashtbl.replace n.literals l c;
                  c
            in
            insert child rest
        | Path_repr.Parameter { or_not_found = true; parses; _ } :: rest ->
            let c = empty_node () in
            n.declining_params <- n.declining_params @ [ (parses, c) ];
            insert c rest
        | Path_repr.Parameter { or_not_found = false; _ } :: rest ->
            let c =
              match n.plain_param with
              | Some c -> c
              | None ->
                  let c = empty_node () in
                  n.plain_param <- Some c;
                  c
            in
            insert c rest
        | Path_repr.Rest _ :: _ -> n.rest_routes <- n.rest_routes @ [ (r, i) ]
      in
      insert root (segments_of r))
    routes;
  root

(* Position by position: a literal, then a declining parameter, then a plain
   one, then a rest; among routes alike at every position, the one listed
   first. Declining parameters alike at a position are compared by the ranks
   of what follows, an end outranking a rest that took nothing. A plain
   parameter that does not parse still matches, and its dependency reports
   it. An empty segment is never a parameter nor part of a rest. Without
   [rest] no rest is tried. *)
let match_rest ~rest n meth segs =
  if (not rest) || List.exists (String.equal "") segs then None
  else
    List.find_map
      (fun (r, i) ->
        if Meth.equal (meth_of r) meth then Some (r, [ -1 ], i) else None)
      n.rest_routes

let rec find_route ~rest:with_rest n meth = function
  | [] -> (
      match
        List.find_map
          (fun (r, i) ->
            if Meth.equal (meth_of r) meth then Some (r, [ 0 ], i) else None)
          n.ends_here
      with
      | Some found -> Some found
      | None -> match_rest ~rest:with_rest n meth [])
  | s :: rest as segs -> (
      let descend rank child =
        Option.map
          (fun (r, ranks, i) -> (r, rank :: ranks, i))
          (find_route ~rest:with_rest child meth rest)
      in
      match Option.bind (Hashtbl.find_opt n.literals s) (descend 2) with
      | Some found -> Some found
      | None when String.equal s "" -> None
      | None -> (
          let better_match ((_, ra, ia) as a) ((_, rb, ib) as b) =
            match List.compare Int.compare ra rb with
            | 0 -> if ia <= ib then a else b
            | c -> if c > 0 then a else b
          in
          match
            List.fold_left
              (fun found (parses, child) ->
                if not (parses s) then found
                else
                  match (found, descend 1 child) with
                  | None, m | m, None -> m
                  | Some a, Some b -> Some (better_match a b))
              None n.declining_params
          with
          | Some found -> Some found
          | None -> (
              match Option.bind n.plain_param (descend 0) with
              | Some found -> Some found
              | None -> match_rest ~rest:with_rest n meth segs)))

(* A rest takes what is left, in the form its codec reads. *)
let params_of_segments r segs =
  let rec collect acc segments segs =
    match (segments, segs) with
    | Path_repr.Rest name :: _, left ->
        List.rev ((name, Path_repr.join_rest left) :: acc)
    | Path_repr.Parameter { name; _ } :: more, s :: left ->
        collect ((name, s) :: acc) more left
    | Path_repr.Literal _ :: more, _ :: left -> collect acc more left
    | [], _ | (Path_repr.Parameter _ | Path_repr.Literal _) :: _, [] ->
        List.rev acc
  in
  collect [] (segments_of r) segs

let find_with_params ~rest t meth segs =
  Option.map
    (fun (r, _, _) -> (r, params_of_segments r segs))
    (find_route ~rest t.table meth segs)

let make ?(middleware = []) ?(codes = []) ?not_found ?cors ?compress
    ?(check_origin = true) ?(trusted_origins = []) ?(trailing_slash = Strict)
    routes =
  let rec check_all = function
    | [] -> check_codes ~codes routes
    | r :: rest -> (
        match (check r, List.find_opt (could_match_alike r) rest) with
        | Error m, _ -> Error m
        | Ok (), Some other ->
            Error
              (Printf.sprintf "%s and %s could both answer one URL"
                 (route_name r) (route_name other))
        | Ok (), None -> check_all rest)
  in
  Result.map
    (fun () ->
      {
        routes;
        table = compile routes;
        methods =
          List.fold_left
            (fun acc r ->
              let m = meth_of r in
              if List.exists (Meth.equal m) acc then acc else acc @ [ m ])
            [] routes;
        not_found;
        middleware;
        codes;
        check_origin;
        trusted_origins;
        cors;
        compress;
        trailing_slash;
      })
    (check_all routes)

(* Cut at its slashes, then each piece decoded: an encoded "/" is inside a
   segment. *)
let path_segments path =
  match String.split_on_char '/' path with
  (* The root has no segment, not one empty segment. *)
  | [ ""; "" ] -> Some []
  | "" :: rest -> Some (List.map Uri.pct_decode rest)
  | _ -> None

let routes t = List.map Route.info t.routes

(* A trailing slash makes another path: two spellings split caches and
   links, so it is strict unless the application asks to redirect. *)
let lookup ?(rest = true) t meth path =
  match path_segments path with
  | None -> `None
  | Some segs -> (
      match find_with_params ~rest t meth segs with
      | Some found -> `Found found
      | None -> (
          match List.rev segs with
          | "" :: (_ :: _ as before) -> (
              match
                ( find_with_params ~rest t meth (List.rev before),
                  t.trailing_slash )
              with
              | Some _, Redirect -> `Slash
              | Some _, Strict | None, _ -> `None)
          | _ -> `None))

(* The only place a refusal's detail is written, which keeps it out of
   every response body. *)
let log_refusal req (response, answered) =
  (match Response.refused response with
  | Some ({ Refusal.detail = Some detail; code; raised; _ } as r) ->
      let level =
        if Status.to_int (Refusal.status r) >= 500 then Logs.Error
        else Logs.Warning
      in
      let fields =
        [
          ("http.request.method", `String (Meth.to_string (Request.meth req)));
          ("url.path", `String (Request.path req));
          ("spindle.refusal.code", `String (Refusal.Code.name code));
        ]
        @ (match answered.route with
          | Some p -> [ ("http.route", `String p) ]
          | None -> [])
        @ match raised with Some (ex, bt) -> Log.raised ex bt | None -> []
      in
      L.msg level (fun m ->
          m "%s %s: %s: %s"
            (Meth.to_string (Request.meth req))
            (Request.path req) (Refusal.Code.name code) detail
            ~tags:(Log.tags fields))
  | Some { Refusal.detail = None; _ } | None -> ());
  (let route = Option.value answered.route ~default:(Request.path req) in
   match answered.undeclared with
   | Some (Code code) ->
       L.warn (fun m ->
           m "%s refused with %s, which nothing declares" route
             (Refusal.Code.name code))
   | Some (Status status) ->
       L.warn (fun m ->
           m "%s answered %d, which it does not list" route
             (Status.to_int status))
   | None -> ());
  (response, answered)

let with_raise_as_500 (h : handler) req =
  match h req with
  | response -> response
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      Response.refusal (Refusal.raised ex bt)

(* Only for a path: "//host/x/" is a URL on another host, and so is
   "/\host/x/" to a browser, so a redirect to either would be open. *)
let location_without_slash req =
  let target = Request.target req in
  let path, rest =
    match String.index_opt target '?' with
    | Some i ->
        (String.sub target 0 i, String.sub target i (String.length target - i))
    | None -> (target, "")
  in
  let n = String.length path in
  if
    n > 1
    && path.[0] = '/'
    && path.[n - 1] = '/'
    && not (path.[1] = '/' || path.[1] = '\\')
  then Some (String.sub path 0 (n - 1) ^ rest)
  else None

(* As a Host header would spell it, an IPv6 address in brackets. The scheme
   is not compared: the same host on another scheme is the same operator. *)
let origin_host origin =
  let u = Uri.of_string origin in
  let host h =
    let h = String.lowercase_ascii h in
    if String.contains h ':' then "[" ^ h ^ "]" else h
  in
  match (Uri.host u, Uri.port u) with
  | Some h, Some p -> Some (host h ^ ":" ^ string_of_int p)
  | Some h, None -> Some (host h)
  | None, _ -> None

(* A browser says where a request came from, by [Sec-Fetch-Site] or, if it
   is older, [Origin]. A request with neither is not a browser's, and
   forgery is a browser's attack. An opaque origin, [null], is a sandboxed
   frame or a redirect's, any site's, so no list can trust it. *)
let is_cross_site t req =
  let origin = Request.header req "origin" in
  let trusted () =
    match origin with
    | Some "null" | None -> false
    | Some o -> List.exists (String.equal o) t.trusted_origins
  in
  match
    Option.map String.lowercase_ascii (Request.header req "sec-fetch-site")
  with
  | Some ("same-origin" | "none") -> false
  | Some _ -> not (trusted ())
  | None -> (
      match origin with
      | None -> false
      | Some o -> (
          (not (trusted ()))
          &&
          match (origin_host o, Request.host req) with
          | Some a, Some b -> not (String.equal a b)
          | None, _ | _, None -> true))

let is_unsafe_method = function
  | `GET | `HEAD | `OPTIONS -> false
  | `POST | `PUT | `PATCH | `DELETE | `Other _ -> true

(* Decided from the method and path before any middleware runs, so a
   middleware can ask which route matched. *)
type resolution =
  | Route of Route_repr.t * (string * string) list
  | Slash  (** a trailing slash, redirected *)
  | Allowed of Meth.t list  (** the path is a route's under other methods *)
  | Unimplemented  (** a method nothing here knows *)
  | Nothing  (** no route's: the not-found answer *)

(* RFC 9110 §9.1: a method no route declares and the framework does not
   know is not implemented. *)
let is_implemented t = function
  | `Other _ as m -> List.exists (Meth.equal m) t.methods
  | `GET | `HEAD | `POST | `PUT | `PATCH | `DELETE | `OPTIONS -> true

let resolve t req =
  let path = Request.path req in
  let meth = match Request.meth req with `HEAD -> `GET | m -> m in
  let methods_allowed ~rest =
    List.filter
      (fun m ->
        match lookup ~rest t m path with
        | `Found _ | `Slash -> true
        | `None -> false)
      t.methods
  in
  let allowed_with_head allow =
    Allowed
      (if List.exists (Meth.equal `GET) allow then allow @ [ `HEAD ] else allow)
  in
  let takes_rest (r : Route_repr.t) =
    List.exists
      (function
        | Path_repr.Rest _ -> true
        | Path_repr.Literal _ | Path_repr.Parameter _ -> false)
      r.segments
  in
  if not (is_implemented t meth) then Unimplemented
  else
    (* A path a route names under any method is that route's, 405 for other
       methods; a rest takes only what nobody names. *)
    match lookup t meth path with
    | `Found (r, params) when takes_rest r -> (
        match methods_allowed ~rest:false with
        | [] -> Route (r, params)
        | allow -> allowed_with_head allow)
    | `Found (r, params) -> Route (r, params)
    | `Slash -> Slash
    | `None -> (
        match methods_allowed ~rest:false with
        | [] -> (
            match methods_allowed ~rest:true with
            | [] -> Nothing
            | allow -> allowed_with_head allow)
        | allow -> allowed_with_head allow)

let matched_route = function
  | Route ((r : Route_repr.t), _) -> Some r.info
  | Slash | Allowed _ | Unimplemented | Nothing -> None

(* A preflight asks about the path, not the method. *)
let routes_at_path t path =
  let under ~rest =
    List.filter_map
      (fun m ->
        match lookup ~rest t m path with
        | `Found ((r : Route_repr.t), _) -> Some r.info
        | `Slash | `None -> None)
      t.methods
  in
  match under ~rest:false with [] -> under ~rest:true | infos -> infos

(* HEAD wherever GET is (RFC 9110 §9.3.2). *)
let allowed_methods infos =
  let ms =
    List.fold_left
      (fun acc (i : Route_repr.info) ->
        if List.exists (Meth.equal i.meth) acc then acc else acc @ [ i.meth ])
      [] infos
  in
  if List.exists (Meth.equal `GET) ms then ms @ [ `HEAD ] else ms

(* The framework answers a preflight on any path a covered route answers. *)
let preflight t req =
  match
    ( t.cors,
      Request.meth req,
      Request.header req "origin",
      Request.header req "access-control-request-method" )
  with
  | Some cors, `OPTIONS, Some origin, Some _ -> (
      match
        List.filter (Cors_repr.covers cors)
          (routes_at_path t (Request.path req))
      with
      | [] -> None
      | covered ->
          Some
            (Response.empty ~status:`No_content
               ~headers:
                 (Cors_repr.preflight cors ~origin
                    ~allow:(allowed_methods covered)
                    ~requested:
                      (Request.header req "access-control-request-headers"))
               ()))
  | (Some _ | None), _, _, _ -> None

(* The innermost handler. The origin check comes first: forgery is refused
   whatever route it names. *)
let answer_resolution t ~body ~answered_route resolution req =
  let meth = match Request.meth req with `HEAD -> `GET | m -> m in
  (* A browser opens a socket with the page's cookies, so it is checked as
     a POST is. *)
  let opens_socket =
    match resolution with
    | Route ((r : Route_repr.t), _) -> (
        match r.info.returns with
        | Returns_repr.Websocket _ -> true
        | Returns_repr.Json _ | Json_response _ | Html | Text | Empty _
        | Empty_response _ | Response | Events _ ->
            false)
    | Slash | Allowed _ | Unimplemented | Nothing -> false
  in
  (* A site the policy lets read a covered route may write to it; under Any,
     only without a cookie. *)
  let cors_trusts =
    match (t.cors, resolution, Request.header req "origin") with
    | Some cors, Route ((r : Route_repr.t), _), Some origin
      when Cors_repr.covers cors r.info ->
        Cors_repr.trusts cors ~origin
          ~cookie:(Option.is_some (Request.header req "cookie"))
    | (Some _ | None), _, (Some _ | None) -> false
  in
  if
    t.check_origin
    && (is_unsafe_method meth || opens_socket)
    && (not cors_trusts) && is_cross_site t req
  then Response.refusal Refusal.cross_origin
  else
    match resolution with
    | Route (r, params) ->
        answered_route := Some (pattern_of r);
        with_raise_as_500 (fun req -> Route_repr.handle r req ~params ~body) req
    | Slash -> (
        match location_without_slash req with
        | Some location ->
            Response.redirect ~status:`Permanent_redirect location
        | None -> Response.refusal Refusal.not_found)
    | Allowed allow -> Response.refusal (Refusal.method_not_allowed ~allow)
    | Unimplemented -> Response.refusal Refusal.not_implemented
    | Nothing -> (
        match t.not_found with
        | Some f -> with_raise_as_500 f req
        | None -> Response.refusal Refusal.not_found)

(* A compressible type always varies by Accept-Encoding, and is gzipped where
   the client takes gzip and nothing forbids it: a coding of its own,
   no-transform, a partial or empty status, a route that opted out, a body
   too small, or a stream of a known length, which is a file served
   precompressed. *)
let choose_gzip t req matched response =
  match t.compress with
  | None -> (response, None)
  | Some c
    when not (Compress_repr.compressible c (Response.content_type response)) ->
      (response, None)
  | Some c ->
      let varies =
        List.exists
          (fun (k, v) ->
            String.equal (String.lowercase_ascii k) "vary"
            && List.exists
                 (fun e ->
                   String.equal (String.lowercase_ascii e) "accept-encoding")
                 (Spindle_http.Field.elements v))
          (Response.headers response)
      in
      let response =
        if varies then response
        else Response.add_headers [ ("vary", "Accept-Encoding") ] response
      in
      let takes_gzip =
        (* Several lines are one list (RFC 9110 §5.3). *)
        match
          Spindle_http.Field.all (Request.headers req) "accept-encoding"
        with
        | [] -> false
        | lines -> (
            match
              Spindle_http.Accept.parse_weighted (String.concat ", " lines)
            with
            | Ok w ->
                Option.equal String.equal
                  (Spindle_http.Accept.choose_encoding w [ "gzip"; "identity" ])
                  (Some "gzip")
            | Error _ -> false)
      in
      let headers = Response.headers response in
      let has_header name =
        Option.is_some (Spindle_http.Field.find headers name)
      in
      let no_transform =
        match Spindle_http.Field.find headers "cache-control" with
        | Some v -> (
            match Spindle_http.Cache_control.parse v with
            | Ok d -> List.mem_assoc "no-transform" d
            | Error _ -> false)
        | None -> false
      in
      let route_opted_out =
        match matched with
        | Some (info : Route.info) ->
            Option.is_some (Meta.find Compress_repr.never info.meta)
        | None -> false
      in
      let large_enough =
        match Response.content response with
        | Response.Buffered s -> String.length s >= c.min_bytes
        | Response.Stream { length = None; _ } -> true
        | Response.Stream { length = Some _; _ } | Response.Takeover _ -> false
      in
      let is_whole =
        match Status.to_int (Response.status response) with
        | 206 | 204 | 304 -> false
        | _ -> true
      in
      if
        takes_gzip
        && (not (has_header "content-encoding"))
        && (not no_transform) && (not route_opted_out) && large_enough
        && is_whole
      then (response, Some c.level)
      else (response, None)

(* A raise is caught at the route, so the access log names it, and again
   around the middleware, so a middleware's bug is one 500 rather than a
   dropped connection. *)
let handle t req ~body =
  let answered_route = ref None in
  let resolution = resolve t req in
  let matched = matched_route resolution in
  let req =
    match matched with Some info -> Route_repr.mark info req | None -> req
  in
  let response =
    match preflight t req with
    | Some answer -> answer
    | None ->
        with_raise_as_500
          (List.fold_right
             (fun m h -> m h)
             t.middleware
             (answer_resolution t ~body ~answered_route resolution))
          req
  in
  (* On every answer of a covered route, a middleware's included, so an
     allowed page can read why it was refused. *)
  let response =
    match (t.cors, matched) with
    | Some cors, Some info when Cors_repr.covers cors info ->
        Response.add_headers
          (Cors_repr.answer_headers cors ~origin:(Request.header req "origin"))
          response
    | (Some _ | None), (Some _ | None) -> response
  in
  (* Judged on what the whole chain answered. *)
  let undeclared =
    match (Response.refused response, matched) with
    | Some r, _ ->
        let route =
          match matched with
          | Some (info : Route.info) -> info.codes
          | None -> []
        in
        if
          List.exists
            (Refusal.Code.equal r.code)
            (Refusal.Code.framework @ t.codes @ route)
        then None
        else Some (Code r.code)
    (* Only a success is the route's to list. *)
    | None, Some (info : Route.info) ->
        let status = Response.status response in
        let n = Status.to_int status in
        if
          n >= 200 && n <= 299
          && not (Returns_repr.declares info.returns status)
        then Some (Status status)
        else None
    | None, None -> None
  in
  let access =
    match matched with
    | Some (info : Route.info) ->
        Option.value (Meta.find Meta.access info.meta) ~default:Logs.Info
    | None -> Logs.Info
  in
  let response, gzip = choose_gzip t req matched response in
  log_refusal req
    (response, { route = !answered_route; undeclared; access; gzip })

(* The first route, in listed order, that cannot start: a server missing
   one route's files is not the server that was written. *)
let start t ~fs =
  let fs = (fs :> Eio.Fs.dir_ty Eio.Path.t) in
  List.fold_left
    (fun started (r : Route_repr.t) ->
      Result.bind started (fun () ->
          match r.start with
          | None -> Ok ()
          | Some start ->
              Result.map_error
                (fun m -> Printf.sprintf "%s: %s" (route_name r) m)
                (start fs)))
    (Ok ()) t.routes
