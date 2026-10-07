(* RFC 9651's published tests, run whole: every file in
   structured-field-tests/, httpwg/structured-field-tests at 00462dd, its
   licence beside it. A record is parsed as its field's type from its lines
   joined with ", ", compared with what it expects, and serialised back to
   its canonical form; a serialisation record serialises what it expects.
   Both sides are shown the same way and the shown text compared, so what
   is checked is the value and not how it is built. *)

module S = Spindle_http.Structured
module U = Yojson.Safe.Util

let dir = "structured-field-tests"

(* ------------------------------------------------------------------ *)
(* The tests' own encodings *)

(* Binary content is base32 in the tests (RFC 4648 §6). *)
let base32 s =
  let value c =
    match c with
    | 'A' .. 'Z' -> Some (Char.code c - Char.code 'A')
    | '2' .. '7' -> Some (Char.code c - Char.code '2' + 26)
    | _ -> None
  in
  let out = Buffer.create (String.length s) in
  let bits = ref 0 and held = ref 0 in
  String.iter
    (fun c ->
      match value c with
      | Some v ->
          held := (!held lsl 5) lor v;
          bits := !bits + 5;
          if !bits >= 8 then (
            bits := !bits - 8;
            Buffer.add_char out (Char.chr ((!held lsr !bits) land 0xff)))
      | None -> ())
    s;
  Buffer.contents out

(* A decimal as thousandths, rounded half to even from its own digits (RFC
   9651 §4.1.5): what an application does before it builds one, since
   thousandths hold no fourth digit. *)
let thousandths f =
  let text = Printf.sprintf "%.15g" (Float.abs f) in
  if String.contains text 'e' then None
  else
    let whole, fraction =
      match String.index_opt text '.' with
      | Some i ->
          ( String.sub text 0 i,
            String.sub text (i + 1) (String.length text - i - 1) )
      | None -> (text, "")
    in
    let fraction = fraction ^ "0000" in
    match
      (int_of_string_opt whole, int_of_string_opt (String.sub fraction 0 3))
    with
    | Some w, Some kept ->
        let rest = String.sub fraction 3 (String.length fraction - 3) in
        let base = (w * 1000) + kept in
        let tie =
          rest.[0] = '5'
          && String.for_all (Char.equal '0')
               (String.sub rest 1 (String.length rest - 1))
        in
        let up =
          rest.[0] > '5' || (rest.[0] = '5' && ((not tie) || base mod 2 = 1))
        in
        let n = if up then base + 1 else base in
        Some (if f < 0. then -n else n)
    | _ -> None

let ( let* ) = Option.bind

let all f xs =
  List.fold_right
    (fun x acc ->
      let* acc = acc in
      let* y = f x in
      Some (y :: acc))
    xs (Some [])

let bare_of : Yojson.Safe.t -> S.bare option = function
  | `Int n -> Some (S.Integer n)
  | `Float f -> Option.map (fun t -> S.Decimal t) (thousandths f)
  | `String s -> Some (S.String s)
  | `Bool b -> Some (S.Boolean b)
  | `Assoc _ as o -> (
      let value = U.member "value" o in
      match (U.member "__type" o, value) with
      | `String "token", `String t -> Some (S.Token t)
      | `String "binary", `String b -> Some (S.Bytes (base32 b))
      | `String "date", `Int n -> Some (S.Date n)
      | `String "displaystring", `String d -> Some (S.Display d)
      | _ -> None)
  | _ -> None

let pair f = function
  | `List [ `String k; v ] -> Option.map (fun v -> (k, v)) (f v)
  | _ -> None

let parameters_of = function `List ps -> all (pair bare_of) ps | _ -> None

let item_of = function
  | `List [ b; ps ] ->
      let* b = bare_of b in
      let* ps = parameters_of ps in
      Some (b, ps)
  | _ -> None

(* A bare item is never a JSON array, so one in an item's first place is an
   inner list's items. *)
let member_of = function
  | `List [ `List items; ps ] ->
      let* items = all item_of items in
      let* ps = parameters_of ps in
      Some (S.Inner (items, ps))
  | j -> Option.map (fun i -> S.Item i) (item_of j)

(* ------------------------------------------------------------------ *)
(* Showing a value *)

let show_bare = function
  | S.Integer n -> "i" ^ string_of_int n
  | S.Decimal t -> "d" ^ string_of_int t
  | S.String s -> "s" ^ String.escaped s
  | S.Token t -> "t" ^ t
  | S.Bytes b -> "b" ^ String.escaped b
  | S.Boolean b -> "?" ^ string_of_bool b
  | S.Date n -> "@" ^ string_of_int n
  | S.Display d -> "%" ^ String.escaped d

let show_parameters ps =
  String.concat "" (List.map (fun (k, v) -> ";" ^ k ^ "=" ^ show_bare v) ps)

let show_item (b, ps) = show_bare b ^ show_parameters ps

let show_member = function
  | S.Item i -> show_item i
  | S.Inner (items, ps) ->
      "("
      ^ String.concat " " (List.map show_item items)
      ^ ")" ^ show_parameters ps

let show_list ms = "[" ^ String.concat ", " (List.map show_member ms) ^ "]"

let show_dictionary d =
  "{"
  ^ String.concat ", " (List.map (fun (k, m) -> k ^ ":" ^ show_member m) d)
  ^ "}"

(* ------------------------------------------------------------------ *)
(* A record *)

(* What the field reads as, shown and serialised, or why not. *)
let read header_type input =
  match header_type with
  | "item" ->
      Result.map (fun v -> (show_item v, S.item_to_string v)) (S.item input)
  | "list" ->
      Result.map (fun v -> (show_list v, S.list_to_string v)) (S.list input)
  | "dictionary" ->
      Result.map
        (fun v -> (show_dictionary v, S.dictionary_to_string v))
        (S.dictionary input)
  | t -> Error ("no such type " ^ t)

(* What a record expects, as a value: shown, and serialised. *)
let expected header_type j =
  match header_type with
  | "item" ->
      Option.map (fun v -> (show_item v, S.item_to_string v)) (item_of j)
  | "list" -> (
      match j with
      | `List ms ->
          Option.map
            (fun v -> (show_list v, S.list_to_string v))
            (all member_of ms)
      | _ -> None)
  | "dictionary" -> (
      match j with
      | `List ms ->
          Option.map
            (fun v -> (show_dictionary v, S.dictionary_to_string v))
            (all (pair member_of) ms)
      | _ -> None)
  | _ -> None

let flag name r = match U.member name r with `Bool b -> b | _ -> false

let lines name r =
  match U.member name r with
  | `List ls -> Some (List.map U.to_string ls)
  | _ -> None

let parsing_case r =
  let name = U.to_string (U.member "name" r) in
  Alcotest.test_case name `Quick (fun () ->
      let header_type = U.to_string (U.member "header_type" r) in
      let raw = Option.value (lines "raw" r) ~default:[] in
      let got = read header_type (String.concat ", " raw) in
      if flag "must_fail" r then
        match got with
        | Error _ -> ()
        | Ok (shown, _) -> Alcotest.failf "read as %s, where it must fail" shown
      else
        match (got, expected header_type (U.member "expected" r)) with
        | Error _, _ when flag "can_fail" r -> ()
        | Error e, _ -> Alcotest.failf "refused: %s" e
        | Ok _, None -> Alcotest.fail "the expected value is not one"
        | Ok (shown, serialised), Some (wanted, _) ->
            Alcotest.(check string) "read" wanted shown;
            let canonical = Option.value (lines "canonical" r) ~default:raw in
            Alcotest.(check (result string string))
              "serialised"
              (Ok (String.concat ", " canonical))
              serialised)

let serialising_case r =
  let name = U.to_string (U.member "name" r) in
  Alcotest.test_case name `Quick (fun () ->
      let header_type = U.to_string (U.member "header_type" r) in
      match
        (expected header_type (U.member "expected" r), flag "must_fail" r)
      with
      | None, true | Some (_, Error _), true -> ()
      | Some (_, Ok s), true ->
          Alcotest.failf "serialised as %s, where it must fail" s
      | None, false -> Alcotest.fail "the value is not one"
      | Some (_, serialised), false ->
          let canonical = Option.value (lines "canonical" r) ~default:[] in
          Alcotest.(check (result string string))
            "serialised"
            (Ok (String.concat ", " canonical))
            serialised)

let records file = U.to_list (Yojson.Safe.from_file file)

let () =
  let json f = Filename.check_suffix f ".json" in
  let files d =
    List.sort String.compare (List.filter json (Array.to_list (Sys.readdir d)))
  in
  Alcotest.run "structured"
    (List.map
       (fun f -> (f, List.map parsing_case (records (Filename.concat dir f))))
       (files dir)
    @ List.map
        (fun f ->
          let d = Filename.concat dir "serialisation-tests" in
          ( "serialising " ^ f,
            List.map serialising_case (records (Filename.concat d f)) ))
        (files (Filename.concat dir "serialisation-tests")))
