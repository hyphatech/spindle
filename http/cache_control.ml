module A = Angstrom
module G = Grammar

type t = (string * string option) list

(* cache-directive = token [ "=" ( token / quoted-string ) ] *)
let directive =
  A.(
    let+ name = G.token
    and+ argument = option None (char '=' *> G.value >>| Option.some) in
    (String.lowercase_ascii name, argument))

let parse = G.parse ~what:"a Cache-Control value" (G.list_of directive)

(* Read back rather than checked piece by piece, so what is written is
   exactly what the reader takes: a name that is no token, or not
   lower-cased, an argument no quoted string holds. *)
let to_string t =
  let s =
    String.concat ", "
      (List.map
         (function n, None -> n | n, Some v -> n ^ "=" ^ Field.quoted v)
         t)
  in
  match parse s with
  | Ok read
    when List.equal
           (fun (n, v) (m, w) ->
             String.equal n m && Option.equal String.equal v w)
           read t ->
      Ok s
  | Ok _ | Error _ -> Error "directives their reader would not read back"

(* RFC 9111 §1.2.2: a delta-seconds too large to hold is read as 2^31. *)
let max_delta_seconds = 2_147_483_648

let delta_seconds t name =
  let name = String.lowercase_ascii name in
  match
    List.find_map (fun (n, v) -> if String.equal n name then Some v else None) t
  with
  | Some (Some v)
    when String.length v > 0
         && String.for_all (function '0' .. '9' -> true | _ -> false) v ->
      Some
        (match int_of_string_opt v with
        | Some n when n <= max_delta_seconds -> n
        | Some _ | None -> max_delta_seconds)
  | Some (Some _) | Some None | None -> None
