(* A cookie as the framework holds it: writing [Set-Cookie], reading
   [Cookie], encoding a value. [Cookie] is the public side. *)

type same_site = Strict | Lax

type t = {
  name : string;
  value : string;
  path : string;
  max_age : int option;
  http_only : bool;
  same_site : same_site;
  seal : (now:int -> string -> string) option;
      (** a signed or encrypted cookie's value as written at that instant *)
}

(* RFC 6265's token is RFC 9110's tchar. *)
let is_token s =
  String.length s > 0
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
         | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^'
         | '_' | '`' | '|' | '~' ->
             true
         | _ -> false)
       s

(* RFC 6265's cookie-octet: no space, quote, comma, semicolon or backslash. *)
let is_cookie_octet = function
  | '\x21'
  | '\x23' .. '\x2B'
  | '\x2D' .. '\x3A'
  | '\x3C' .. '\x5B'
  | '\x5D' .. '\x7E' ->
      true
  | _ -> false

let is_valid_value v =
  let n = String.length v in
  let inner =
    if n >= 2 && v.[0] = '"' && v.[n - 1] = '"' then String.sub v 1 (n - 2)
    else v
  in
  String.for_all is_cookie_octet inner

let is_valid_path p =
  String.for_all
    (fun c -> Char.code c >= 0x20 && Char.code c < 0x7f && c <> ';')
    p

(* Stamped with the instant it was made; reading holds it to its age. *)
type sealer = {
  seal : now:int -> string -> string;
  unseal : now:int -> string -> string option;
}

(* Declared once and used both ways, so the name has one spelling and the
   value is never printed by hand. *)
type 'a named = {
  cookie : string;
  codec : 'a Codec.t;
  sealer : sealer option;
  age : int option;  (** a signed or encrypted cookie's, in seconds *)
}

let checked_name name =
  if is_token name then name
  else invalid_arg (Printf.sprintf "Cookie.named: %S is not a cookie name" name)

let named name codec =
  { cookie = checked_name name; codec; sealer = None; age = None }

module Named = struct
  let name n = n.cookie
  let codec n = n.codec
  let sealed n = Option.is_some n.sealer

  let unseal n ~now raw =
    match n.sealer with None -> Some raw | Some s -> s.unseal ~now raw
end

(* The message names the cookie and never its value, which may be a
   credential. *)
let make_cookie ?(path = "/") ?max_age ?(http_only = true) ?(same_site = Lax)
    name value =
  if not (is_valid_value value) then
    invalid_arg
      (Printf.sprintf "Cookie.make: cookie %s has a value no cookie can hold"
         name)
  else if not (is_valid_path path) then
    invalid_arg
      (Printf.sprintf "Cookie.make: cookie %s has a path no cookie can hold"
         name)
  else { name; value; path; max_age; http_only; same_site; seal = None }

(* Base64url with no padding: every character of it is a cookie-octet. *)
let encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let decode s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
  (* One spelling per value. *)
  | Ok d when String.equal (encode d) s -> Some d
  | Ok _ | Error _ -> None

(* A sealed cookie's declared age caps [max_age]: reading holds it to that
   age whatever the browser was told. *)
let make ?path ?max_age ?http_only ?same_site n v =
  let max_age =
    match (max_age, n.age) with
    | Some a, Some b -> Some (min a b)
    | Some a, None | None, Some a -> Some a
    | None, None -> None
  in
  let printed = Codec.print n.codec v in
  match n.sealer with
  | None -> make_cookie ?path ?max_age ?http_only ?same_site n.cookie printed
  | Some s ->
      (* Sealed as base64url, which any cookie holds. *)
      {
        (make_cookie ?path ?max_age ?http_only ?same_site n.cookie "") with
        value = printed;
        seal = Some s.seal;
      }

(* Signed: stamp, value and a MAC over the name, stamp and value, joined by
   dots, so a value cannot move to another cookie or change its stamp.
   Encrypted: stamp and value sealed with the name as associated data. *)
let seconds_of_ms now = now / 1000

let is_expired ~age ~now stamp =
  match age with Some age -> seconds_of_ms now - stamp > age | None -> false

let signed ring ?max_age name codec =
  let cookie = checked_name name in
  let signed_payload stamp v = String.concat "\000" [ cookie; stamp; v ] in
  let seal ~now v =
    let stamp = string_of_int (seconds_of_ms now) in
    String.concat "."
      [ stamp; encode v; encode (Key.sign ring (signed_payload stamp v)) ]
  in
  let unseal ~now raw =
    match String.split_on_char '.' raw with
    | [ stamp; v; mac ] -> (
        match (int_of_string_opt stamp, decode v, decode mac) with
        | Some t, Some v, Some mac
          when Key.verify ring ~mac (signed_payload stamp v)
               && not (is_expired ~age:max_age ~now t) ->
            Some v
        | _ -> None)
    | _ -> None
  in
  { cookie; codec; sealer = Some { seal; unseal }; age = max_age }

let encrypted ring ?max_age name codec =
  let cookie = checked_name name in
  let seal ~now v =
    encode
      (Key.seal ring ~adata:cookie
         (string_of_int (seconds_of_ms now) ^ "." ^ v))
  in
  let unseal ~now raw =
    match Option.bind (decode raw) (Key.unseal ring ~adata:cookie) with
    | None -> None
    | Some opened -> (
        match String.index_opt opened '.' with
        | None -> None
        | Some i -> (
            match int_of_string_opt (String.sub opened 0 i) with
            | Some t when not (is_expired ~age:max_age ~now t) ->
                Some (String.sub opened (i + 1) (String.length opened - i - 1))
            | Some _ | None -> None))
  in
  { cookie; codec; sealer = Some { seal; unseal }; age = max_age }

let clear ?path n = make_cookie ?path ~max_age:0 n.cookie ""

(* SameSite is always written. [Lax] by default: a link from a chat window
   is a cross-site navigation, which [Strict] sends without the cookie,
   and [Lax] still withholds it from a cross-site POST. *)
let to_header ~secure ~now (t : t) =
  let value =
    match t.seal with None -> t.value | Some seal -> seal ~now t.value
  in
  String.concat "; "
    (List.concat
       [
         [ t.name ^ "=" ^ value; "Path=" ^ t.path ];
         (if t.http_only then [ "HttpOnly" ] else []);
         (if secure then [ "Secure" ] else []);
         [
           (match t.same_site with
           | Strict -> "SameSite=Strict"
           | Lax -> "SameSite=Lax");
         ];
         (match t.max_age with
         | None -> []
         | Some n -> [ "Max-Age=" ^ string_of_int n ]);
       ])

let parse header =
  List.filter_map
    (fun pair ->
      match String.index_opt pair '=' with
      | None -> None
      | Some i ->
          let name = String.trim (String.sub pair 0 i) in
          let value =
            String.trim (String.sub pair (i + 1) (String.length pair - i - 1))
          in
          if String.equal name "" then None else Some (name, value))
    (String.split_on_char ';' header)
