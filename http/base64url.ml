let alphabet = Base64.uri_safe_alphabet

let decode s =
  let in_alphabet = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
    | _ -> false
  in
  if not (String.for_all in_alphabet s) then None
  else
    match Base64.decode ~pad:false ~alphabet s with
    | Error _ -> None
    | Ok octets ->
        (* Written again, a text whose unused bits were set differs. *)
        if String.equal (Base64.encode_string ~pad:false ~alphabet octets) s
        then Some octets
        else None
