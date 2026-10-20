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
  seal : (Key_repr.ring -> now:Ptime.t -> string -> string) option;
      (** a signed or encrypted cookie's value as written at that instant, under
          the server's keys *)
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

(* What a cookie-octet leaves out would end the value or write an attribute
   of its own, so a plain value is written with it percent-encoded, and the
   % that marks an escape with it: any text is a value a cookie holds, and a
   word, a tag or a token keeps its spelling. *)
let escape v =
  let b = Buffer.create (String.length v) in
  String.iter
    (fun c ->
      if is_cookie_octet c && c <> '%' then Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    v;
  Buffer.contents b

(* Any escape reads as its byte, in either case, since a browser's script
   encodes more than it must; one that is not two hex digits is no value
   anybody wrote. *)
let unescape v =
  let hex = function
    | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
    | 'a' .. 'f' as c -> Some (Char.code c - Char.code 'a' + 10)
    | 'A' .. 'F' as c -> Some (Char.code c - Char.code 'A' + 10)
    | _ -> None
  in
  let n = String.length v in
  let b = Buffer.create n in
  let rec from i =
    if i >= n then Some (Buffer.contents b)
    else if v.[i] <> '%' then (
      Buffer.add_char b v.[i];
      from (i + 1))
    else if i + 2 >= n then None
    else
      match (hex v.[i + 1], hex v.[i + 2]) with
      | Some high, Some low ->
          Buffer.add_char b (Char.chr ((high * 16) + low));
          from (i + 3)
      | (Some _ | None), (Some _ | None) -> None
  in
  from 0

let is_valid_path p =
  String.for_all
    (fun c -> Char.code c >= 0x20 && Char.code c < 0x7f && c <> ';')
    p

(* Stamped with the instant it was made; reading holds it to its age. *)
type sealer = {
  seal : Key_repr.ring -> now:Ptime.t -> string -> string;
  unseal : Key_repr.ring -> now:Ptime.t -> string -> string option;
}

(* Declared once and used both ways, so the name has one spelling and the
   value is never printed by hand. *)
type 'a named = {
  cookie : string;
  codec : 'a Codec.t;
  sealer : sealer option;
  age : int option;
      (** a signed or encrypted cookie's, which it always has, in seconds *)
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

  let unseal n ~keys ~now raw =
    match n.sealer with
    | None -> unescape raw
    | Some s -> s.unseal keys ~now raw
end

(* [value] is one a cookie holds: a plain one escaped, a sealed one
   base64url. A path is a constant written in source. *)
let make_cookie ?(path = "/") ?max_age ?(http_only = true) ?(same_site = Lax)
    name value =
  if not (is_valid_path path) then
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

(* A sealed cookie's declared age caps [max_age_s]: reading holds it to that
   age whatever the browser was told. *)
let make ?path ?max_age_s ?http_only ?same_site n v =
  let max_age =
    match (max_age_s, n.age) with
    | Some a, Some b -> Some (min a b)
    | Some a, None | None, Some a -> Some a
    | None, None -> None
  in
  match n.sealer with
  | None ->
      make_cookie ?path ?max_age ?http_only ?same_site n.cookie
        (escape (Codec.print n.codec v))
  | Some s ->
      (* Sealed as base64url, which any cookie holds. *)
      {
        (make_cookie ?path ?max_age ?http_only ?same_site n.cookie "") with
        value = Codec.print n.codec v;
        seal = Some s.seal;
      }

(* Signed: stamp, value and a MAC over the name, stamp and value, joined by
   dots, so a value cannot move to another cookie or change its stamp.
   Encrypted: stamp and value sealed with the name as associated data. *)
let stamp_of now =
  let d, ps = Ptime.Span.to_d_ps (Ptime.to_span now) in
  string_of_int ((d * 86_400) + Int64.to_int (Int64.div ps 1_000_000_000_000L))

(* The stamp is to the second, and so is its age read. *)
let is_expired ~age_s ~now stamp =
  match Ptime.of_span (Ptime.Span.of_int_s (stamp + age_s)) with
  | Some last -> Ptime.is_later (Ptime.truncate ~frac_s:0 now) ~than:last
  | None -> true

(* [Max-Age] and the stamp count whole seconds: an age rounded up, so the
   cookie never ends before the span it was declared with. *)
let whole_seconds span =
  Int64.to_int
    (Int64.unsigned_div
       (Int64.add (Mtime.Span.to_uint64_ns span) 999_999_999L)
       1_000_000_000L)

let signed ~max_age name codec =
  let max_age_s = whole_seconds max_age in
  let cookie = checked_name name in
  let signed_payload stamp v = String.concat "\000" [ cookie; stamp; v ] in
  let seal ring ~now v =
    let stamp = stamp_of now in
    String.concat "."
      [
        stamp;
        encode v;
        encode (Key_repr.sign_cookie ring (signed_payload stamp v));
      ]
  in
  let unseal ring ~now raw =
    match String.split_on_char '.' raw with
    | [ stamp; v; mac ] -> (
        match (int_of_string_opt stamp, decode v, decode mac) with
        | Some t, Some v, Some mac
          when Key_repr.verify_cookie ring ~mac (signed_payload stamp v)
               && not (is_expired ~age_s:max_age_s ~now t) ->
            Some v
        | _ -> None)
    | _ -> None
  in
  { cookie; codec; sealer = Some { seal; unseal }; age = Some max_age_s }

let encrypted ~max_age name codec =
  let max_age_s = whole_seconds max_age in
  let cookie = checked_name name in
  let seal ring ~now v =
    encode (Key_repr.seal_cookie ring ~adata:cookie (stamp_of now ^ "." ^ v))
  in
  let unseal ring ~now raw =
    match
      Option.bind (decode raw) (Key_repr.unseal_cookie ring ~adata:cookie)
    with
    | None -> None
    | Some opened -> (
        match String.index_opt opened '.' with
        | None -> None
        | Some i -> (
            match int_of_string_opt (String.sub opened 0 i) with
            | Some t when not (is_expired ~age_s:max_age_s ~now t) ->
                Some (String.sub opened (i + 1) (String.length opened - i - 1))
            | Some _ | None -> None))
  in
  { cookie; codec; sealer = Some { seal; unseal }; age = Some max_age_s }

let clear ?path n = make_cookie ?path ~max_age:0 n.cookie ""

(* SameSite is always written. [Lax] by default: a link from a chat window
   is a cross-site navigation, which [Strict] sends without the cookie,
   and [Lax] still withholds it from a cross-site POST. *)
let header ~secure (t : t) value =
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

let to_header ~secure ~now ~keys (t : t) =
  match (t.seal, keys) with
  | None, _ -> Ok (header ~secure t t.value)
  | Some seal, Some ring -> Ok (header ~secure t (seal ring ~now t.value))
  | Some _, None ->
      Error
        (Printf.sprintf
           "the cookie %s is signed or encrypted, and the server was given no \
            ~keys to seal it with"
           t.name)

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
