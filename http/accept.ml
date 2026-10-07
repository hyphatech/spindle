module A = Angstrom
module G = Grammar

type range = {
  type_ : string;
  subtype : string;
  parameters : (string * string) list;
  weight : int;
}

(* qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] ), read as
   thousandths. *)
let qvalue v =
  let thousandths frac =
    String.length frac <= 3
    && String.for_all (function '0' .. '9' -> true | _ -> false) frac
  in
  match String.split_on_char '.' v with
  | [ "0" ] -> Some 0
  | [ "1" ] -> Some 1000
  | [ "0"; frac ] when thousandths frac ->
      int_of_string_opt (frac ^ String.make (3 - String.length frac) '0')
  | [ "1"; frac ] when thousandths frac && String.for_all (Char.equal '0') frac
    ->
      Some 1000
  | _ -> None

(* The parameters before [q] are the range's; RFC 9110 puts nothing after
   it. *)
let split_weight parameters =
  let rec from before = function
    | [] -> Some (List.rev before, 1000)
    | [ ("q", v) ] -> Option.map (fun w -> (List.rev before, w)) (qvalue v)
    | ("q", _) :: _ :: _ -> None
    | p :: rest -> from (p :: before) rest
  in
  from [] parameters

let with_weight p =
  A.(
    p >>= fun (v, parameters) ->
    match split_weight parameters with
    | Some (parameters, weight) -> return (v, parameters, weight)
    | None -> fail "a weight")

let range =
  A.(
    with_weight
      (let+ type_ = G.token
       and+ _ = char '/'
       and+ subtype = G.token
       and+ parameters = G.parameters in
       ( (String.lowercase_ascii type_, String.lowercase_ascii subtype),
         parameters ))
    >>| fun ((type_, subtype), parameters, weight) ->
    { type_; subtype; parameters; weight })

let parse_media = G.parse ~what:"an Accept value" (G.list_of range)

let parse_weighted =
  G.parse ~what:"a weighted list"
    (G.list_of
       A.(
         with_weight
           (let+ token = G.token and+ parameters = G.parameters in
            (String.lowercase_ascii token, parameters))
         >>= function
         | token, [], weight -> return (token, weight)
         | _, _ :: _, _ -> fail "a parameter"))

(* The highest weight wins, the earlier offer among equals; [weight_of] is
   [None] where nothing accepts the offer. *)
let highest_weighted weight_of offers =
  List.fold_left
    (fun chosen offer ->
      match (weight_of offer, chosen) with
      | Some w, Some (_, w') when w <= w' -> chosen
      | Some w, _ when w > 0 -> Some (offer, w)
      | Some _, _ | None, _ -> chosen)
    None offers
  |> Option.map fst

let specificity r =
  match (r.type_, r.subtype) with
  | "*", "*" -> 0
  | _, "*" -> 1
  | _ -> 2 + List.length r.parameters

let range_matches r (m : Media_type.t) =
  (String.equal r.type_ "*" || String.equal r.type_ m.type_)
  && (String.equal r.subtype "*" || String.equal r.subtype m.subtype)
  && List.for_all
       (fun (n, v) ->
         Option.equal String.equal (Media_type.parameter m n) (Some v))
       r.parameters

let most_specific ranges fits =
  List.fold_left
    (fun found (r, rank) ->
      if not (fits r) then found
      else
        match found with
        | Some (_, rank') when rank' >= rank -> found
        | Some _ | None -> Some (r, rank))
    None ranges

let choose_media ranges offers =
  match ranges with
  | [] -> List.nth_opt offers 0
  | _ ->
      let ranked = List.map (fun r -> (r, specificity r)) ranges in
      highest_weighted
        (fun m ->
          Option.map
            (fun (r, _) -> r.weight)
            (most_specific ranked (fun r -> range_matches r m)))
        offers

let choose_language ranges tags =
  match ranges with
  | [] -> List.nth_opt tags 0
  | _ ->
      let ranked =
        List.map
          (fun (range, w) ->
            ( (range, w),
              if String.equal range "*" then 0 else String.length range ))
          ranges
      in
      highest_weighted
        (fun tag ->
          let tag' = String.lowercase_ascii tag in
          Option.map
            (fun ((_, w), _) -> w)
            (most_specific ranked (fun (range, _) ->
                 String.equal range "*" || String.equal range tag'
                 || String.starts_with ~prefix:(range ^ "-") tag')))
        tags

(* A named token decides for itself; [*] decides for what is not named. *)
let weight_of_token ranges token =
  let token = String.lowercase_ascii token in
  match List.assoc_opt token ranges with
  | Some w -> Some w
  | None -> List.assoc_opt "*" ranges

let choose_token ranges tokens =
  match ranges with
  | [] -> List.nth_opt tokens 0
  | _ -> highest_weighted (weight_of_token ranges) tokens

let choose_encoding ranges codings =
  highest_weighted
    (fun coding ->
      match (weight_of_token ranges coding, String.lowercase_ascii coding) with
      | Some w, _ -> Some w
      | None, "identity" -> Some 1
      | None, _ -> None)
    codings
