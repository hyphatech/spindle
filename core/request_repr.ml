(* A request as the framework holds it; private, so only the framework sets
   the route it matched. *)

module Meth = Spindle_http.Meth

type body_error = Too_large | Unreadable of string | Busy

(* Extended by [Route], which is built on this module and so cannot be
   named here. *)
type matched = ..

(* The one header a trusted proxy writes, and the only one believed. *)
type proxy_header = X_forwarded_for | Forwarded

type t = {
  id : string;
  meth : Meth.t;
  target : string;
  path : string;
  uri : Uri.t Lazy.t;
      (** parsed when a query is asked for, which most requests never do *)
  version : Spindle_http.Head.version;
  host : string option;  (** as the head named it *)
  headers : (string * string) list;  (** names lower-cased *)
  peer : string;
  client : string;
  proxied : bool;
  proxy_header : proxy_header;
  now : unit -> int;
  matched : matched option;  (** set once the route table has chosen *)
}

(* As the client spelled it: [Uri.path] would turn a segment of "%2F" into a
   separator. Only an absolute-form target, a proxy's, goes through [Uri]. *)
let path_of target uri =
  if String.length target > 0 && target.[0] = '/' then
    match String.index_opt target '?' with
    | Some i -> String.sub target 0 i
    | None -> target
  else Uri.path (Lazy.force uri)

let make ?id ?(peer = "") ?client ?(proxied = false)
    ?(proxy_header = X_forwarded_for) ?(version = Spindle_http.Head.Http_1_1)
    ?host ?(headers = []) ~now meth target =
  let host =
    match host with
    | Some h -> Some h
    | None -> (
        match Spindle_http.Field.find headers "host" with
        | Some "" | None -> None
        | Some h -> Some h)
  in
  let uri = lazy (Uri.of_string target) in
  {
    id = (match id with Some id -> id | None -> Log.fresh_id ());
    meth;
    target;
    path = path_of target uri;
    uri;
    version;
    host;
    headers = List.map (fun (k, v) -> (String.lowercase_ascii k, v)) headers;
    peer;
    client = Option.value client ~default:peer;
    proxied;
    proxy_header;
    now;
    matched = None;
  }

let with_matched m t = { t with matched = Some m }
let matched t = t.matched
let meth t = t.meth
let version t = t.version
let target t = t.target
let path t = t.path
let query t name = Uri.get_query_param (Lazy.force t.uri) name

(* [Uri] keeps each occurrence of a name as its own entry. *)
let queries t name =
  List.concat_map
    (fun (k, vs) -> if String.equal k name then vs else [])
    (Uri.query (Lazy.force t.uri))

let headers t = t.headers

let header t name =
  List.assoc_opt (String.lowercase_ascii name) t.headers
  |> Option.map String.trim

(* Several Cookie headers are one list: HTTP/2 splits it freely. *)
let cookie t name =
  List.filter_map
    (fun (k, v) -> if String.equal k "cookie" then Some v else None)
    t.headers
  |> List.concat_map Cookie_repr.parse
  |> List.assoc_opt name

let id t = t.id
let peer t = t.peer
let proxied t = t.proxied
let proxy_header t = t.proxy_header
let client t = t.client
let now t = t.now ()
let loopback_hosts = [ "localhost"; "127.0.0.1"; "[::1]" ]

(* Only a trusted proxy, in the header it writes, may say a request came
   over https or for another host. Its word is the last, since what is
   before it is the client's. *)
let proxy_says t ~x_forwarded ~forwarded =
  let values_of name =
    List.filter_map
      (fun (k, v) -> if String.equal k name then Some v else None)
      t.headers
  in
  let first_opt = function l :: _ -> Some l | [] -> None in
  if not t.proxied then None
  else
    match t.proxy_header with
    | X_forwarded_for ->
        first_opt
          (List.rev
             (List.concat_map Spindle_http.Field.elements
                (values_of x_forwarded)))
    | Forwarded -> (
        match
          Spindle_http.Forwarded.parse
            (String.concat ", " (values_of "forwarded"))
        with
        | Ok elements -> Option.bind (first_opt (List.rev elements)) forwarded
        | Error _ -> None)

let forwarded_host t =
  proxy_says t ~x_forwarded:"x-forwarded-host" ~forwarded:(fun e -> e.host)

let forwarded_proto t =
  proxy_says t ~x_forwarded:"x-forwarded-proto" ~forwarded:(fun e -> e.proto)

let host t =
  let lower = Option.map String.lowercase_ascii in
  match forwarded_host t with Some h -> lower (Some h) | None -> lower t.host

(* Exactly a loopback host: "localhost.example.com" is someone else's. *)
let secure t =
  match Option.map String.lowercase_ascii (forwarded_proto t) with
  | Some "https" -> true
  | Some _ | None -> (
      match host t with
      | None -> true
      | Some host ->
          not
            (List.exists
               (fun name ->
                 String.equal host name
                 || String.starts_with ~prefix:(name ^ ":") host)
               loopback_hosts))
