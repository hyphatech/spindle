type version = Http_1_0 | Http_1_1
type error = Closed | Refused of Status.t * string

(* Raised inside this module only; [read] answers it as a value. *)
exception Refuse of Status.t * string

let refuse_bad_request detail = raise (Refuse (`Bad_request, detail))
let is_visible c = Char.code c > 0x20 && Char.code c < 0x7f
let is_ows c = Char.equal c ' ' || Char.equal c '\t'
let is_digit c = c >= '0' && c <= '9'

let is_hex = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

(* [Buf_read.line] ends a line at CRLF or a bare LF, which RFC 9112 §2.2 lets
   a recipient accept; a CR left inside the line is a bare CR, which it does
   not. *)
let read_line ~max ~used ic =
  let l = Eio.Buf_read.line ic in
  used := !used + String.length l + 2;
  if !used > max then
    raise (Refuse (`Request_header_fields_too_large, "a head past the limit"))
  else if String.contains l '\r' then refuse_bad_request "a bare CR"
  else l

let parse_field l =
  match Field.parse l with
  | Ok f -> f
  | Error detail -> refuse_bad_request detail

(* Up to the empty line. A line beginning with whitespace is an obsolete
   fold, which [Field.parse] refuses unless [unfold] joins it to the field
   before, as a user agent must (RFC 9112 §5.2). *)
let read_fields ~max ~used ~unfold ic =
  let rec more acc =
    match read_line ~max ~used ic with
    | "" -> List.rev acc
    | l when unfold && is_ows l.[0] -> (
        match acc with
        | f :: rest -> (
            match Field.unfold f l with
            | Ok f -> more (f :: rest)
            | Error detail -> refuse_bad_request detail)
        | [] -> refuse_bad_request "whitespace before the first field")
    | l -> more (parse_field l :: acc)
  in
  more []

(* [Cut] is the peer leaving after the start line and before the empty line,
   which a server and a client answer differently. A connection that failed
   under the read -- reset, refused -- is the peer leaving too. *)
type 'a head_read = Head of 'a | No_head | Cut | Bad of Status.t * string

(* A start line past the limit is [start_too_long] rather than 431: for a
   request it is the target that was too long. *)
let read_head ~max ~start_too_long ~skip_blank_lines ~unfold ic parse_start =
  let used = ref 0 and started = ref false in
  let rec start_line () =
    match read_line ~max ~used ic with
    | "" when skip_blank_lines -> start_line ()
    | l -> l
    | exception
        ( Refuse (`Request_header_fields_too_large, _)
        | Eio.Buf_read.Buffer_limit_exceeded ) ->
        let status, detail = start_too_long in
        raise (Refuse (status, detail))
  in
  match
    let start = parse_start (start_line ()) in
    started := true;
    (start, read_fields ~max ~used ~unfold ic)
  with
  | head -> Head head
  | exception (End_of_file | Eio.Io _) -> if !started then Cut else No_head
  | exception Refuse (status, detail) -> Bad (status, detail)
  | exception Eio.Buf_read.Buffer_limit_exceeded ->
      Bad (`Request_header_fields_too_large, "a line past the limit")

(* A later minor version is read as HTTP/1.1 (RFC 9110 §6.2). *)
let version_of_string v =
  if
    String.length v = 8
    && String.starts_with ~prefix:"HTTP/" v
    && is_digit v.[5]
    && Char.equal v.[6] '.'
    && is_digit v.[7]
  then
    match (v.[5], v.[7]) with
    | '1', '0' -> Http_1_0
    | '1', _ -> Http_1_1
    | _ -> raise (Refuse (`Http_version_not_supported, "version " ^ v))
  else refuse_bad_request (Printf.sprintf "a version %S" v)

(* RFC 9112 §9.3 asks about [close] first. An HTTP/1.0 message with
   Transfer-Encoding cannot be trusted to end where it seems to, so its
   connection closes after it (§6.1). *)
let keep_alive version headers =
  let close = Field.has_element headers "connection" "close" in
  match version with
  | Http_1_1 -> not close
  | Http_1_0 ->
      (not close)
      && Field.has_element headers "connection" "keep-alive"
      && List.is_empty (Field.all headers "transfer-encoding")

(* RFC 3986's unreserved and sub-delims. *)
let is_reg_name_char = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9'
  | '-' | '.' | '_' | '~' | '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ','
  | ';' | '=' ->
      true
  | _ -> false

let is_reg_name s =
  let n = String.length s in
  let rec from i =
    i >= n
    || (is_reg_name_char s.[i] && from (i + 1))
    || Char.equal s.[i] '%'
       && i + 2 < n
       && is_hex s.[i + 1]
       && is_hex s.[i + 2]
       && from (i + 3)
  in
  from 0

(* 0 to 255, with no leading zero. *)
let is_dec_octet s =
  let n = String.length s in
  n >= 1 && n <= 3 && String.for_all is_digit s
  && (n = 1 || s.[0] <> '0')
  && int_of_string s <= 255

let is_ipv4 s =
  match String.split_on_char '.' s with
  | [ a; b; c; d ] -> List.for_all is_dec_octet [ a; b; c; d ]
  | _ -> false

let is_h16 s =
  String.length s >= 1 && String.length s <= 4 && String.for_all is_hex s

let rec find_double_colon s i =
  if i + 1 >= String.length s then None
  else if s.[i] = ':' && s.[i + 1] = ':' then Some i
  else find_double_colon s (i + 1)

(* Eight groups, the last two of which may be an IPv4 address, and at most
   one "::" standing for one or more groups of zeros. *)
let is_ipv6 s =
  let groups ~last side =
    let rec count = function
      | [] -> Some 0
      | [ g ] when last && is_ipv4 g -> Some 2
      | g :: rest -> if is_h16 g then Option.map succ (count rest) else None
    in
    if String.equal side "" then Some 0
    else count (String.split_on_char ':' side)
  in
  match find_double_colon s 0 with
  | None -> (
      match groups ~last:true s with Some 8 -> true | Some _ | None -> false)
  | Some i -> (
      let left = String.sub s 0 i in
      let right = String.sub s (i + 2) (String.length s - i - 2) in
      match (groups ~last:false left, groups ~last:true right) with
      | Some l, Some r -> l + r <= 7
      | _ -> false)

(* "v" 1*HEXDIG "." 1*( unreserved / sub-delims / ":" ) *)
let is_ipv_future s =
  let n = String.length s in
  match String.index_opt s '.' with
  | Some i when i >= 2 && (s.[0] = 'v' || s.[0] = 'V') && i + 1 < n ->
      String.for_all is_hex (String.sub s 1 (i - 1))
      && String.for_all
           (fun c -> is_reg_name_char c || c = ':')
           (String.sub s (i + 1) (n - i - 1))
  | Some _ | None -> false

(* uri-host [ ":" port ] (RFC 9110 §7.2) as its host and port: a bracketed
   IPv6 address or IPvFuture (RFC 3986 §3.2.2), or a reg-name, which an IPv4
   address also is. Empty is a host: a client sends it for a target with no
   authority (RFC 9112 §3.2). *)
let parse_authority s =
  let n = String.length s in
  let with_port host rest =
    if String.equal rest "" then Some (host, None)
    else if rest.[0] = ':' then
      let port = String.sub rest 1 (String.length rest - 1) in
      if String.for_all is_digit port then Some (host, Some port) else None
    else None
  in
  if n > 0 && s.[0] = '[' then
    match String.index_opt s ']' with
    | Some j ->
        let literal = String.sub s 1 (j - 1) in
        if is_ipv6 literal || is_ipv_future literal then
          with_port (String.sub s 0 (j + 1)) (String.sub s (j + 1) (n - j - 1))
        else None
    | None -> None
  else
    let i = Option.value (String.index_opt s ':') ~default:n in
    let host = String.sub s 0 i in
    if is_reg_name host then with_port host (String.sub s i (n - i)) else None

let valid_host s = Option.is_some (parse_authority s)

module Request = struct
  type form = Origin | Absolute | Authority | Asterisk

  type t = {
    meth : Meth.t;
    target : string;
    form : form;
    version : version;
    headers : (string * string) list;
    host : string option;
  }

  let meth_of_string = function
    | "GET" -> `GET
    | "HEAD" -> `HEAD
    | "POST" -> `POST
    | "PUT" -> `PUT
    | "PATCH" -> `PATCH
    | "DELETE" -> `DELETE
    | "OPTIONS" -> `OPTIONS
    | m -> `Other m

  let is_scheme_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '+' | '-' | '.' -> true
    | _ -> false

  (* Userinfo is refused (RFC 9110 §4.2.4), since it makes one authority
   look like another, and so is an http URI with no host (§4.2.1). *)
  let absolute_authority target =
    match String.index_opt target ':' with
    | Some i
      when i > 0
           && (match target.[0] with
             | 'a' .. 'z' | 'A' .. 'Z' -> true
             | _ -> false)
           && String.for_all is_scheme_char (String.sub target 0 i) ->
        let scheme = String.lowercase_ascii (String.sub target 0 i) in
        let rest = String.sub target (i + 1) (String.length target - i - 1) in
        let is_web =
          String.equal scheme "http" || String.equal scheme "https"
        in
        if not (String.starts_with ~prefix:"//" rest) then
          if is_web then refuse_bad_request "an http target with no authority"
          else None
        else
          let rest = String.sub rest 2 (String.length rest - 2) in
          let stop =
            match
              List.filter_map
                (fun c -> String.index_opt rest c)
                [ '/'; '?'; '#' ]
            with
            | [] -> String.length rest
            | ends -> List.fold_left min (String.length rest) ends
          in
          let authority = String.sub rest 0 stop in
          if String.contains authority '@' then
            refuse_bad_request "a target with userinfo"
          else if not (valid_host authority) then
            refuse_bad_request "a target's authority"
          else if is_web && String.equal authority "" then
            refuse_bad_request "an http target with no host"
          else Some authority
    | Some _ | None -> refuse_bad_request "a target in no form a request has"

  (* RFC 9112 §3.2: authority-form is CONNECT's, asterisk-form a server-wide
     OPTIONS, and any other target that is not a path is absolute. *)
  let target_form meth target =
    match (meth, target) with
    | `Other "CONNECT", t -> (
        match parse_authority t with
        | Some (host, Some port)
          when not (String.equal host "" || String.equal port "") ->
            (Authority, Some t)
        | Some _ | None ->
            refuse_bad_request "a CONNECT target that is not host:port")
    | `OPTIONS, "*" -> (Asterisk, None)
    | _, "*" ->
        refuse_bad_request "an asterisk target for a method other than OPTIONS"
    | _, t when Char.equal t.[0] '/' -> (Origin, None)
    | _, t -> (Absolute, absolute_authority t)

  let parse_request_line line =
    match String.split_on_char ' ' line with
    | [ m; target; v ] ->
        if not (Field.is_token m) then
          refuse_bad_request (Printf.sprintf "a method %S" m)
        else if String.equal target "" || not (String.for_all is_visible target)
        then refuse_bad_request "a target that is not visible ASCII"
        else
          let meth = meth_of_string m in
          let version = version_of_string v in
          let form, authority = target_form meth target in
          (meth, target, form, version, authority)
    | _ ->
        refuse_bad_request
          "a request line that is not three words, one space apart"

  (* RFC 9112 §3.2: an HTTP/1.1 request carries exactly one valid Host,
     whatever its form; an absolute-form target's authority overrides it
     (§3.2.2). *)
  let request_host ~version ~authority headers =
    match (Field.all headers "host", version) with
    | [], Http_1_1 -> refuse_bad_request "an HTTP/1.1 request with no Host"
    | _ :: _ :: _, _ -> refuse_bad_request "more than one Host"
    | [ h ], _ when not (valid_host h) -> refuse_bad_request "an invalid Host"
    | hosts, (Http_1_0 | Http_1_1) -> (
        match (authority, hosts) with
        | Some a, _ when not (String.equal a "") -> Some a
        | _, [ h ] when not (String.equal h "") -> Some h
        | _ -> None)

  let read ~max ic =
    match
      read_head ~max
        ~start_too_long:(`Uri_too_long, "a request line past the limit")
        ~skip_blank_lines:true ~unfold:false ic parse_request_line
    with
    | No_head | Cut -> Error Closed
    | Bad (status, detail) -> Error (Refused (status, detail))
    | Head ((meth, target, form, version, authority), headers) -> (
        match request_host ~version ~authority headers with
        | host -> Ok { meth; target; form; version; headers; host }
        | exception Refuse (status, detail) -> Error (Refused (status, detail)))

  let keep_alive t = keep_alive t.version t.headers
end

module Response = struct
  type t = {
    version : version;
    status : Status.t;
    reason : string;
    headers : (string * string) list;
  }

  (* HTTP-version SP 3DIGIT SP [reason] (RFC 9112 §4). A missing space after
     the code is read rather than refused: a client ignores the reason. *)
  let parse_status_line l =
    match String.index_opt l ' ' with
    | None -> refuse_bad_request "a status line with no code"
    | Some i ->
        let version = version_of_string (String.sub l 0 i) in
        let rest = String.sub l (i + 1) (String.length l - i - 1) in
        let code, reason =
          if String.length rest = 3 then (rest, "")
          else
            match String.index_opt rest ' ' with
            | Some 3 ->
                (String.sub rest 0 3, String.sub rest 4 (String.length rest - 4))
            | Some _ | None ->
                refuse_bad_request "a status code that is not three digits"
        in
        if not (String.for_all is_digit code) then
          refuse_bad_request (Printf.sprintf "a status code %S" code)
        else
          let n = int_of_string code in
          (* RFC 9110 §15. *)
          if n < 100 || n > 599 then
            refuse_bad_request (Printf.sprintf "a status code %d" n)
          else if not (Field.is_text reason) then
            refuse_bad_request "a control character in the reason"
          else (version, Status.of_int n, reason)

  let read ~max ic =
    match
      read_head ~max
        ~start_too_long:(`Bad_request, "a status line past the limit")
        ~skip_blank_lines:false ~unfold:true ic parse_status_line
    with
    | No_head -> Error `Closed
    | Cut -> Error (`Malformed "a head cut short")
    | Bad (_, detail) -> Error (`Malformed detail)
    | Head ((version, status, reason), headers) ->
        Ok { version; status; reason; headers }

  let keep_alive t = keep_alive t.version t.headers
end
