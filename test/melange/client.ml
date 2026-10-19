(* Printed by Spindle from test/melange/app.ml. Do not edit: run dune promote. *)

(* What every printed module opens with, before its types: a problem as the
   server says one, the kinds' types, and the readers and writers the
   printed code is made of. It is Melange over Js.Json, Js.Date and Js.Dict
   alone, so a printed module needs no library. *)

(** What is wrong with a document: where, a code to branch on, and a sentence
    about that one place, as the server reports them. *)
module Problem = struct
  type code =
    | Syntax
    | Too_deep
    | Required
    | Unexpected_type
    | Too_small
    | Too_large
    | Not_a_multiple
    | Too_short
    | Too_long
    | Too_few
    | Too_many
    | Unknown_word
    | Unknown_member
    | Repeated_member
    | Malformed
    | Too_many_problems

  let code_to_string = function
    | Syntax -> "syntax"
    | Too_deep -> "too_deep"
    | Required -> "required"
    | Unexpected_type -> "unexpected_type"
    | Too_small -> "too_small"
    | Too_large -> "too_large"
    | Not_a_multiple -> "not_a_multiple"
    | Too_short -> "too_short"
    | Too_long -> "too_long"
    | Too_few -> "too_few"
    | Too_many -> "too_many"
    | Unknown_word -> "unknown_word"
    | Unknown_member -> "unknown_member"
    | Repeated_member -> "repeated_member"
    | Malformed -> "malformed"
    | Too_many_problems -> "too_many_problems"

  type t = { at : string; code : code; message : string }
  (** [at] is the path from the root, as the server writes one:
      [items[2].count], or the empty string for the document itself. *)

  let to_string p =
    (match p.at with "" -> "the document" | s -> s)
    ^ ": " ^ p.message ^ " (" ^ code_to_string p.code ^ ")"
end

(* JavaScript's own, where OCaml's standard library has no word for it. *)
external char_code_at : string -> int -> float = "charCodeAt" [@@mel.send]
external code_point_at : string -> int -> float = "codePointAt" [@@mel.send]
external is_integer : float -> bool = "isInteger" [@@mel.scope "Number"]
external is_finite : float -> bool = "isFinite" [@@mel.scope "Number"]
external js_string : float -> string = "String"

external set_utc_full_year : Js.Date.t -> float -> float -> float -> float
  = "setUTCFullYear"
[@@mel.send]

external set_utc_hours : Js.Date.t -> float -> float -> float -> float -> float
  = "setUTCHours"
[@@mel.send]

external utc_full_year : Js.Date.t -> float = "getUTCFullYear" [@@mel.send]
external utc_month : Js.Date.t -> float = "getUTCMonth" [@@mel.send]
external utc_date : Js.Date.t -> float = "getUTCDate" [@@mel.send]
external utc_hours : Js.Date.t -> float = "getUTCHours" [@@mel.send]
external utc_minutes : Js.Date.t -> float = "getUTCMinutes" [@@mel.send]
external utc_seconds : Js.Date.t -> float = "getUTCSeconds" [@@mel.send]

external utc_milliseconds : Js.Date.t -> float = "getUTCMilliseconds"
[@@mel.send]

external url_can_parse : string -> bool = "canParse" [@@mel.scope "URL"]
external to_lower_case : string -> string = "toLowerCase" [@@mel.send]
external slice : string -> int -> int -> string = "slice" [@@mel.send]
external string_includes : string -> string -> bool = "includes" [@@mel.send]
external split : string -> string -> string array = "split" [@@mel.send]
external js_array_from : string -> string array = "from" [@@mel.scope "Array"]
external pad_start : string -> int -> string -> string = "padStart" [@@mel.send]
external to_radix : int -> int -> string = "toString" [@@mel.send]

let digit c = c >= 48. && c <= 57.
let hex c = digit c || (c >= 97. && c <= 102.) || (c >= 65. && c <= 70.)
let alpha c = (c >= 97. && c <= 122.) || (c >= 65. && c <= 90.)

(* [n] digits of [s] at [i], as a number, or -1. *)
let fixed s i n =
  if i + n > String.length s then -1.
  else
    let rec go k acc =
      if k = n then acc
      else
        let c = char_code_at s (i + k) in
        if digit c then go (k + 1) ((acc *. 10.) +. c -. 48.) else -1.
    in
    go 0 0.

let leap y =
  (Float.rem y 4. = 0. && Float.rem y 100. <> 0.) || Float.rem y 400. = 0.

let days_in_month y m =
  if m = 2. then if leap y then 29. else 28.
  else if m = 4. || m = 6. || m = 9. || m = 11. then 30.
  else 31.

let date_at s i =
  if
    i + 10 > String.length s
    || char_code_at s (i + 4) <> 45.
    || char_code_at s (i + 7) <> 45.
  then None
  else
    let y = fixed s i 4 and m = fixed s (i + 5) 2 and d = fixed s (i + 8) 2 in
    if y < 0. || m < 1. || m > 12. || d < 1. || d > days_in_month y m then None
    else Some (y, m, d)

let two n = pad_start (js_string n) 2 "0"
let four n = pad_start (js_string n) 4 "0"

(** An instant, as RFC 3339 writes one: read with any fraction and offset, held
    to the millisecond, written in UTC with milliseconds. *)
module Instant : sig
  type t

  val to_date : t -> Js.Date.t

  val of_date : Js.Date.t -> t option
  (** [None] for an invalid date, and for one outside the years 0000 to 9999,
      which the server refuses. *)

  val to_string : t -> string
  val of_string : string -> t option
end = struct
  type t = Js.Date.t

  let to_date t = t

  let of_date d =
    let ms = Js.Date.getTime d in
    if is_finite ms && utc_full_year d >= 0. && utc_full_year d <= 9999. then
      Some d
    else None

  let to_string t =
    four (utc_full_year t)
    ^ "-"
    ^ two (utc_month t +. 1.)
    ^ "-"
    ^ two (utc_date t)
    ^ "T"
    ^ two (utc_hours t)
    ^ ":"
    ^ two (utc_minutes t)
    ^ ":"
    ^ two (utc_seconds t)
    ^ "."
    ^ pad_start (js_string (utc_milliseconds t)) 3 "0"
    ^ "Z"

  let of_string s =
    let n = String.length s in
    match date_at s 0 with
    | None -> None
    | Some (y, mo, d) -> (
        if
          n < 20
          || char_code_at s 10 <> 84.
          || char_code_at s 13 <> 58.
          || char_code_at s 16 <> 58.
        then None
        else
          let h = fixed s 11 2 and mi = fixed s 14 2 and sec = fixed s 17 2 in
          if h < 0. || h > 23. || mi < 0. || mi > 59. || sec < 0. || sec > 59.
          then None
          else
            (* A fraction is read to the millisecond and the rest dropped. *)
            let i, ms =
              if n > 19 && char_code_at s 19 = 46. then (
                let j = ref 20 in
                while !j < n && digit (char_code_at s !j) do
                  incr j
                done;
                let digits = slice s 20 !j in
                if String.length digits = 0 then (!j, -1.)
                else (!j, fixed (digits ^ "00") 0 3))
              else (19, 0.)
            in
            let offset =
              if ms < 0. then None
              else if i = n - 1 && char_code_at s i = 90. then Some 0.
              else if
                i = n - 6
                && (char_code_at s i = 43. || char_code_at s i = 45.)
                && char_code_at s (i + 3) = 58.
              then
                let oh = fixed s (i + 1) 2 and om = fixed s (i + 4) 2 in
                if oh < 0. || oh > 23. || om < 0. || om > 59. then None
                else
                  let minutes = (oh *. 60.) +. om in
                  Some (if char_code_at s i = 43. then minutes else -.minutes)
              else None
            in
            match offset with
            | None -> None
            | Some minutes ->
                (* Set field by field: Date.UTC reads a year below 100 as
                   one of the 1900s. *)
                let date = Js.Date.fromFloat 0. in
                let (_ : float) = set_utc_full_year date y (mo -. 1.) d in
                let (_ : float) = set_utc_hours date h mi sec ms in
                of_date
                  (Js.Date.fromFloat
                     (Js.Date.getTime date -. (minutes *. 60000.))))
end

(** A duration, as ISO 8601 writes one without years or months, held in
    milliseconds. *)
module Duration : sig
  type t

  val to_ms : t -> float

  val of_ms : float -> t option
  (** [None] for a fraction, a negative number, and one longer than the server
      holds, about 584 years. *)

  val to_string : t -> string
  val of_string : string -> (t, string) result
end = struct
  type t = float

  let day_ms = 86_400_000.

  (* 2^64 - 1 nanoseconds in whole milliseconds, the longest the server
     reads. *)
  let longest_ms = 18_446_744_073_709.
  let to_ms t = t

  let of_ms f =
    if is_integer f && f >= 0. && f <= longest_ms then Some f else None

  let not_a_duration =
    "This must be a duration written as ISO 8601 has it, like PT1H30M: weeks, \
     or days, hours, minutes and seconds, and never years or months."

  let of_string s =
    let n = String.length s in
    let i = ref 1 in
    let number () =
      let start = !i in
      while !i < n && digit (char_code_at s !i) do
        incr i
      done;
      if !i = start || !i - start > 16 then None
      else Some (Js.Float.fromString (slice s start !i))
    in
    let fraction () =
      let c = char_code_at s !i in
      if !i < n && (c = 46. || c = 44.) then (
        incr i;
        let start = !i in
        while !i < n && digit (char_code_at s !i) do
          incr i
        done;
        if !i = start then None else Some (fixed (slice s start !i ^ "00") 0 3))
      else Some 0.
    in
    let designator c =
      if !i < n && char_code_at s !i = c then (
        incr i;
        true)
      else false
    in
    let fail = Error not_a_duration in
    let scaled v unit =
      if v > longest_ms /. unit then longest_ms +. 1. else v *. unit
    in
    let total ms =
      if ms > longest_ms then Error "This duration is too long." else Ok ms
    in
    let time () =
      let components = ref 0 and ms = ref 0. in
      let step unit c =
        if !i < n && digit (char_code_at s !i) then
          let save = !i in
          match number () with
          | None -> false
          | Some v ->
              if designator c then (
                ms := !ms +. scaled v unit;
                incr components;
                true)
              else (
                i := save;
                true)
        else true
      in
      let seconds () =
        if !i < n && digit (char_code_at s !i) then
          match number () with
          | None -> false
          | Some v -> (
              match fraction () with
              | None -> false
              | Some frac ->
                  if designator 83. then (
                    ms := !ms +. scaled v 1000. +. frac;
                    incr components;
                    true)
                  else false)
        else true
      in
      if
        step 3_600_000. 72. && step 60_000. 77. && seconds () && !components > 0
      then Some !ms
      else None
    in
    if n < 2 || char_code_at s 0 <> 80. then fail
    else if char_code_at s 1 = 84. then (
      incr i;
      match time () with
      | Some ms when !i = n -> total ms
      | Some _ | None -> fail)
    else
      match number () with
      | None -> fail
      | Some v ->
          if designator 87. then
            if !i = n then total (scaled v (7. *. day_ms)) else fail
          else if designator 68. then
            let days = scaled v day_ms in
            if !i = n then total days
            else if designator 84. then
              match time () with
              | Some ms when !i = n -> total (days +. ms)
              | Some _ | None -> fail
            else fail
          else fail

  let to_string ms =
    let days = Float.trunc (ms /. day_ms) and rest = Float.rem ms day_ms in
    let h = Float.trunc (rest /. 3_600_000.)
    and m = Float.rem (Float.trunc (rest /. 60_000.)) 60.
    and s = Float.rem (Float.trunc (rest /. 1000.)) 60.
    and frac = Float.rem rest 1000. in
    let b = ref "P" in
    if days > 0. then b := !b ^ js_string days ^ "D";
    if rest > 0. || days = 0. then begin
      b := !b ^ "T";
      if h > 0. then b := !b ^ js_string h ^ "H";
      if m > 0. then b := !b ^ js_string m ^ "M";
      if s > 0. || frac > 0. || rest = 0. then begin
        b := !b ^ js_string s;
        if frac > 0. then begin
          let f = pad_start (js_string frac) 3 "0" in
          let len = ref 3 in
          while char_code_at f (!len - 1) = 48. do
            decr len
          done;
          b := !b ^ "." ^ slice f 0 !len
        end;
        b := !b ^ "S"
      end
    end;
    !b
end

(** A UUID, as RFC 9562 writes one, held in lower case. *)
module Uuid : sig
  type t

  val to_string : t -> string

  val of_string : string -> t option
  (** Read in either case: versions 1 to 8, the nil and the max UUID. *)

  val of_string_version : int -> string -> t option
  (** One version alone, as a description that names one reads it. *)
end = struct
  type t = string

  let to_string t = t

  let check version s =
    let shaped =
      String.length s = 36
      &&
      let ok = ref true in
      for i = 0 to 35 do
        let c = char_code_at s i in
        ok :=
          !ok && if i = 8 || i = 13 || i = 18 || i = 23 then c = 45. else hex c
      done;
      !ok
    in
    let variant =
      shaped
      &&
      let c = char_code_at s 19 in
      c = 56. || c = 57. || c = 97. || c = 98. || c = 65. || c = 66.
    in
    let special =
      s = "00000000-0000-0000-0000-000000000000"
      || s = "ffffffff-ffff-ffff-ffff-ffffffffffff"
    in
    shaped
    &&
    match version with
    | Some v -> char_code_at s 14 = 48. +. float_of_int v && variant
    | None ->
        special
        ||
        let c = char_code_at s 14 in
        c >= 49. && c <= 56. && variant

  let of_string s = if check None s then Some (to_lower_case s) else None

  let of_string_version v s =
    if check (Some v) s then Some (to_lower_case s) else None
end

(* ------------------------------------------------------------------ *)
(* Reading and writing, as the printed code calls them *)

(** The readers and writers a printed module is made of. Nothing here is an
    island's to call: the functions printed for each component are. *)
module Wire = struct
  type segment = Member of string | Index of int | Name of string

  type path = segment list
  (** The innermost segment first. *)

  exception Enough

  type ctx = {
    mutable problems : Problem.t list;
    mutable listed : int;
    limit : int;
  }

  type 'a reader = ctx -> path -> Js.Json.t -> 'a option
  type 'a writer = ctx -> path -> 'a -> Js.Json.t option

  let create () = { problems = []; listed = 0; limit = 100 }

  (* A code point a path quotes, as the server does: one that would end a log
     line or reorder the text around it. *)
  let invisible u =
    (u >= 0x80 && u <= 0x9F)
    || u = 0x2028 || u = 0x2029 || u = 0x61C || u = 0x200E || u = 0x200F
    || (u >= 0x202A && u <= 0x202E)
    || (u >= 0x2066 && u <= 0x2069)

  let plain name =
    name <> ""
    &&
    let ok = ref true in
    Array.iter
      (fun ch ->
        let c = code_point_at ch 0 in
        ok :=
          !ok
          && (alpha c || digit c || c = 95. || c = 45. || c = 36.
             || (c >= 128. && not (invisible (int_of_float c)))))
      (js_array_from name);
    !ok

  (* Quoted as JSON, with what is invisible written as JSON's escape. *)
  let quoted name =
    let b = ref "\"" in
    Array.iter
      (fun ch ->
        let c = int_of_float (code_point_at ch 0) in
        b :=
          !b
          ^
          if c = 34 then "\\\""
          else if c = 92 then "\\\\"
          else if c = 10 then "\\n"
          else if c = 13 then "\\r"
          else if c = 9 then "\\t"
          else if c < 0x20 || c = 0x7F || invisible c then
            "\\u" ^ pad_start (to_lower_case (to_radix c 16)) 4 "0"
          else ch)
      (js_array_from name);
    !b ^ "\""

  let path_to_string (path : path) =
    let b = ref "" in
    let name n =
      if plain n then (
        if !b <> "" then b := !b ^ ".";
        b := !b ^ n)
      else b := !b ^ "[" ^ quoted n ^ "]"
    in
    List.iter
      (function
        | Member n -> name n
        | Name n ->
            name n;
            b := !b ^ "[name]"
        | Index i -> b := !b ^ "[" ^ string_of_int i ^ "]")
      (List.rev path);
    !b

  let report ctx path code message =
    if ctx.listed >= ctx.limit then raise Enough;
    ctx.problems <-
      { Problem.at = path_to_string path; code; message } :: ctx.problems;
    ctx.listed <- ctx.listed + 1

  let sort_found j =
    match Js.Json.classify j with
    | JSONObject _ -> "an object"
    | JSONArray _ -> "a list"
    | JSONString _ -> "text"
    | JSONTrue | JSONFalse -> "true or false"
    | JSONNull -> "null"
    | JSONNumber _ -> "a number"

  let mismatch ctx path expected j =
    report ctx path Unexpected_type
      ("This must be " ^ expected ^ ", not " ^ sort_found j ^ ".");
    None

  let either = function
    | [] -> "nothing at all"
    | [ w ] -> w
    | ws ->
        let rec last = function
          | [ w ] -> ([], w)
          | w :: rest ->
              let init, l = last rest in
              (w :: init, l)
          | [] -> ([], "")
        in
        let init, l = last ws in
        String.concat ", " init ^ " or " ^ l

  let quote_word w = Js.Json.stringify (Js.Json.string w)

  let one_of words =
    match words with
    | [] -> "This must be one of no words at all."
    | [ w ] -> "This must be " ^ w ^ "."
    | ws -> "This must be one of " ^ either ws ^ "."

  (* Every bound a value breaks, each its own problem. *)
  let checked ctx path v broken =
    match broken with
    | [] -> Some v
    | broken ->
        List.iter (fun (code, message) -> report ctx path code message) broken;
        None

  let some f = function None -> [] | Some x -> f x

  (* A number as the server spells one in a sentence: a whole one with no
     point. *)
  let spelled f = js_string f

  (* Zod's own check, as the server has it: the quotient within four
     epsilons of a whole number, scaled by its size. *)
  let multiple f m =
    let ratio = f /. m in
    Float.abs (ratio -. Float.round ratio)
    < 4. *. epsilon_float *. Float.max (Float.abs ratio) 1.

  let number_bounds ~min ~max ~above ~below ~multiple_of f =
    some
      (fun m ->
        if not (f >= m) then
          [ (Problem.Too_small, "This must be at least " ^ spelled m ^ ".") ]
        else [])
      min
    @ some
        (fun m ->
          if not (f <= m) then
            [ (Problem.Too_large, "This must be at most " ^ spelled m ^ ".") ]
          else [])
        max
    @ some
        (fun m ->
          if not (f > m) then
            [
              (Problem.Too_small, "This must be greater than " ^ spelled m ^ ".");
            ]
          else [])
        above
    @ some
        (fun m ->
          if not (f < m) then
            [ (Problem.Too_large, "This must be less than " ^ spelled m ^ ".") ]
          else [])
        below
    @ some
        (fun m ->
          if not (multiple f m) then
            [
              ( Problem.Not_a_multiple,
                "This must be a multiple of " ^ spelled m ^ "." );
            ]
          else [])
        multiple_of

  let whole_bounds ~min ~max ~multiple_of f =
    number_bounds ~min ~max ~above:None ~below:None ~multiple_of:None f
    @ some
        (fun m ->
          if Float.rem f m <> 0. then
            [
              ( Problem.Not_a_multiple,
                "This must be a multiple of " ^ spelled m ^ "." );
            ]
          else [])
        multiple_of

  let code_points s = Array.length (js_array_from s)

  let counted noun k =
    if k = 1 then "1 " ^ noun else string_of_int k ^ " " ^ noun ^ "s"

  let length_bounds ~min_length ~max_length s =
    match (min_length, max_length) with
    | None, None -> []
    | min, max ->
        let n = code_points s in
        some
          (fun m ->
            if n < m then
              [
                ( Problem.Too_short,
                  "This must be at least " ^ counted "character" m ^ " long." );
              ]
            else [])
          min
        @ some
            (fun m ->
              if n > m then
                [
                  ( Problem.Too_long,
                    "This must be at most " ^ counted "character" m ^ " long."
                  );
                ]
              else [])
            max

  let count_bounds noun ~min ~max n =
    some
      (fun m ->
        if n < m then
          [
            (Problem.Too_few, "This must have at least " ^ counted noun m ^ ".");
          ]
        else [])
      min
    @ some
        (fun m ->
          if n > m then
            [
              ( Problem.Too_many,
                "This must have at most " ^ counted noun m ^ "." );
            ]
          else [])
        max

  (* ---------------------------------------------------------------- *)
  (* Readers *)

  let any : Js.Json.t reader = fun _ _ j -> Some j

  let null : unit reader =
   fun ctx path j ->
    match Js.Json.classify j with
    | JSONNull -> Some ()
    | _ -> mismatch ctx path "null" j

  let bool : bool reader =
   fun ctx path j ->
    match Js.Json.classify j with
    | JSONTrue -> Some true
    | JSONFalse -> Some false
    | _ -> mismatch ctx path "true or false" j

  let number ?min ?max ?above ?below ?multiple_of () : float reader =
   fun ctx path j ->
    match Js.Json.classify j with
    | JSONNumber f ->
        checked ctx path f
          (number_bounds ~min ~max ~above ~below ~multiple_of f)
    | _ -> mismatch ctx path "a number" j

  let past_type ctx path negative what =
    report ctx path
      (if negative then Problem.Too_small else Problem.Too_large)
      ("This is "
      ^ (if negative then "smaller" else "larger")
      ^ " than " ^ what ^ " can hold.");
    None

  (* A whole number as a float, which holds one exactly to 2^53: past it the
     browser cannot tell which whole number it is, as Zod cannot. *)
  let whole ?min ?max ?multiple_of () : float reader =
   fun ctx path j ->
    match Js.Json.classify j with
    | JSONNumber f ->
        if not (is_integer f) then (
          report ctx path Unexpected_type
            "This must be a whole number, not a fraction.";
          None)
        else if Float.abs f >= 9007199254740992. then
          past_type ctx path (f < 0.) "a whole number here"
        else checked ctx path f (whole_bounds ~min ~max ~multiple_of f)
    | _ -> mismatch ctx path "a whole number" j

  (* An integer whose bounds lie within 32 bits, which Melange's int holds. *)
  let int ?min ?max ?multiple_of () : int reader =
   fun ctx path j ->
    match
      whole
        ?min:(Option.map float_of_int min)
        ?max:(Option.map float_of_int max)
        ?multiple_of:(Option.map float_of_int multiple_of)
        () ctx path j
    with
    | Some f -> Some (int_of_float f)
    | None -> None

  let text ctx path j =
    match Js.Json.classify j with
    | JSONString s -> Some s
    | _ -> mismatch ctx path "text" j

  let string ?min_length ?max_length () : string reader =
   fun ctx path j ->
    match text ctx path j with
    | Some s -> checked ctx path s (length_bounds ~min_length ~max_length s)
    | None -> None

  (* A kind over text: its length first, then its grammar, a refusal of
     which is [malformed] with the kind's sentence. *)
  let kind ?min_length ?max_length parse : 'a reader =
   fun ctx path j ->
    match string ?min_length ?max_length () ctx path j with
    | None -> None
    | Some s -> (
        match parse s with
        | Ok v -> Some v
        | Error message ->
            report ctx path Malformed message;
            None)

  let refusing message f s =
    match f s with Some v -> Ok v | None -> Error message

  let instant ?min_length ?max_length () =
    kind ?min_length ?max_length
      (refusing
         "This must be an instant written as RFC 3339 has it, like \
          2026-09-30T12:00:00Z."
         Instant.of_string)

  let date ?min_length ?max_length () =
    kind ?min_length ?max_length (fun s ->
        match date_at s 0 with
        | Some (y, m, d) when String.length s = 10 ->
            Ok (int_of_float y, int_of_float m, int_of_float d)
        | Some _ | None ->
            Error "This must be a date written as YYYY-MM-DD, like 2026-09-30.")

  let duration ?min_length ?max_length () =
    kind ?min_length ?max_length Duration.of_string

  let uuid ?min_length ?max_length ?version () =
    kind ?min_length ?max_length (fun s ->
        match version with
        | None ->
            refusing
              "This must be a UUID, like 01890a5d-ac96-7a3b-9e5a-5f1c2a7b8c9d."
              Uuid.of_string s
        | Some v ->
            refusing
              ("This must be a version " ^ string_of_int v
             ^ " UUID, like 01890a5d-ac96-7a3b-9e5a-5f1c2a7b8c9d.")
              (Uuid.of_string_version v) s)

  let sextet ~url c =
    if c >= 65. && c <= 90. then true
    else if c >= 97. && c <= 122. then true
    else if digit c then true
    else if url then c = 45. || c = 95.
    else c = 43. || c = 47.

  let base64_check ~url s =
    let n = String.length s in
    let body =
      if url then if n mod 4 = 1 then -1 else n
      else if n mod 4 <> 0 then -1
      else if
        n >= 2 && char_code_at s (n - 1) = 61. && char_code_at s (n - 2) = 61.
      then n - 2
      else if n >= 1 && char_code_at s (n - 1) = 61. then n - 1
      else n
    in
    body >= 0
    && body mod 4 <> 1
    &&
    let ok = ref true in
    for i = 0 to body - 1 do
      ok := !ok && sextet ~url (char_code_at s i)
    done;
    !ok

  let base64 ?min_length ?max_length () =
    kind ?min_length ?max_length (fun s ->
        if base64_check ~url:false s then Ok s
        else Error "This must be bytes in base64, padded to a multiple of four.")

  let base64url ?min_length ?max_length () =
    kind ?min_length ?max_length (fun s ->
        if base64_check ~url:true s then Ok s
        else Error "This must be bytes in base64url, unpadded.")

  (* Held to the browser's URL, as Zod's check is, and not to the server's
     grammar: the one kind the browser reads more loosely. *)
  let uri ?min_length ?max_length () =
    kind ?min_length ?max_length (fun s ->
        if url_can_parse s then Ok s
        else
          Error
            "This must be a URI with its scheme, like https://example.com/path.")

  let all_digits p =
    let ok = ref true in
    for i = 0 to String.length p - 1 do
      ok := !ok && digit (char_code_at p i)
    done;
    !ok

  let ipv4_check s =
    let parts = split s "." in
    Array.length parts = 4
    && Array.for_all
         (fun p ->
           let n = String.length p in
           n >= 1 && n <= 3 && all_digits p
           && (n = 1 || char_code_at p 0 <> 48.)
           && Js.Float.fromString p <= 255.)
         parts

  let ipv6_check s =
    let group g =
      let n = String.length g in
      n >= 1 && n <= 4
      &&
      let ok = ref true in
      for i = 0 to n - 1 do
        ok := !ok && hex (char_code_at g i)
      done;
      !ok
    in
    let groups ~last part =
      if part = "" then Some 0
      else
        let rec count n = function
          | [] -> Some n
          | [ g ] when last && string_includes g "." ->
              if ipv4_check g then Some (n + 2) else None
          | g :: rest -> if group g && n < 8 then count (n + 1) rest else None
        in
        count 0 (Array.to_list (split part ":"))
    in
    let n = String.length s in
    let rec split_double i =
      if i + 1 >= n then None
      else if char_code_at s i = 58. && char_code_at s (i + 1) = 58. then Some i
      else split_double (i + 1)
    in
    match split_double 0 with
    | None -> ( match groups ~last:true s with Some 8 -> true | _ -> false)
    | Some i -> (
        let left = slice s 0 i and right = slice s (i + 2) n in
        let clean part =
          not
            (String.length part > 0
            && (char_code_at part 0 = 58.
               || char_code_at part (String.length part - 1) = 58.))
        in
        if String.length right >= 1 && char_code_at right 0 = 58. then false
        else if not (clean left && clean right) then false
        else
          match (groups ~last:false left, groups ~last:true right) with
          | Some l, Some r -> l + r <= 7
          | _ -> false)

  let ipv4 ?min_length ?max_length () =
    kind ?min_length ?max_length (fun s ->
        if ipv4_check s then Ok s
        else Error "This must be an IPv4 address, like 192.0.2.1.")

  let ipv6 ?min_length ?max_length () =
    kind ?min_length ?max_length (fun s ->
        if ipv6_check s then Ok s
        else Error "This must be an IPv6 address, like 2001:db8::1.")

  (* An enum: its words quoted in a sentence, as the server quotes them. *)
  let enum words (read : string -> 'a option) : 'a reader =
   fun ctx path j ->
    let quoted () = List.map quote_word (Array.to_list words) in
    match Js.Json.classify j with
    | JSONString s -> (
        match read s with
        | Some v -> Some v
        | None ->
            report ctx path Unknown_word (one_of (quoted ()));
            None)
    | _ -> mismatch ctx path ("one of " ^ either (quoted ())) j

  let array ?min_items ?max_items (elt : 'a reader) : 'a array reader =
   fun ctx path j ->
    match Js.Json.classify j with
    | JSONArray items ->
        let failed = ref false in
        let out =
          Array.mapi
            (fun i x ->
              match elt ctx (Index i :: path) x with
              | Some v -> v
              | None ->
                  failed := true;
                  Obj.magic 0)
            items
        in
        let within =
          checked ctx path ()
            (count_bounds "item" ~min:min_items ~max:max_items
               (Array.length items))
        in
        if !failed || Option.is_none within then None else Some out
    | _ -> mismatch ctx path "a list" j

  (* A list of exactly [n] items, each read by the printed code at its
     index. *)
  let tuple n : Js.Json.t array reader =
   fun ctx path j ->
    match Js.Json.classify j with
    | JSONArray items ->
        if Array.length items = n then Some items
        else (
          report ctx path
            (if Array.length items < n then Too_few else Too_many)
            ("This must have exactly " ^ string_of_int n ^ " items.");
          None)
    | _ -> mismatch ctx path "a list" j

  let members : Js.Json.t Js.Dict.t reader =
   fun ctx path j ->
    match Js.Json.classify j with
    | JSONObject o -> Some o
    | _ -> mismatch ctx path "an object" j

  (* A map's members in the document's order, each name read by the key's
     description as the text it is, with what is wrong with a name said at
     the name. A key read as one another was is a name given twice. *)
  let dict ?min_properties ?max_properties (key : 'k reader) (value : 'v reader)
      : ('k * 'v) array reader =
   fun ctx path j ->
    match members ctx path j with
    | None -> None
    | Some o ->
        let failed = ref false in
        let seen = Js.Dict.empty () in
        let out =
          Array.map
            (fun (name, x) ->
              let at = Member name :: path in
              match key ctx (Name name :: path) (Js.Json.string name) with
              | None ->
                  failed := true;
                  Obj.magic 0
              | Some k ->
                  let spelling = Js.Json.stringify (Obj.magic k) in
                  if Option.is_some (Js.Dict.get seen spelling) then (
                    report ctx at Repeated_member
                      "This member is given more than once.";
                    failed := true;
                    Obj.magic 0)
                  else (
                    Js.Dict.set seen spelling true;
                    match value ctx at x with
                    | Some v -> (k, v)
                    | None ->
                        failed := true;
                        Obj.magic 0))
            (Js.Dict.entries o)
        in
        let within =
          checked ctx path ()
            (count_bounds "member" ~min:min_properties ~max:max_properties
               (Array.length out))
        in
        if !failed || Option.is_none within then None else Some out

  (* A member the object requires. *)
  let required (read : 'a reader) ctx path o name : 'a option =
    match Js.Dict.get o name with
    | Some x -> read ctx (Member name :: path) x
    | None ->
        report ctx (Member name :: path) Required "This is required.";
        None

  (* A member that may be left out: [Some None] when it is. *)
  let optional (read : 'a reader) ctx path o name : 'a option option =
    match Js.Dict.get o name with
    | Some x -> Option.map Option.some (read ctx (Member name :: path) x)
    | None -> Some None

  (* A member that may be left out or null, as [opt_mem] reads one. *)
  let optional_or_null (read : 'a reader) ctx path o name : 'a option option =
    match Js.Dict.get o name with
    | Some x -> (
        match Js.Json.classify x with
        | JSONNull -> Some None
        | _ -> Option.map Option.some (read ctx (Member name :: path) x))
    | None -> Some None

  (* A member the object does not describe, where it refuses them. *)
  let unknown ctx path o (names : string array) =
    Array.iter
      (fun name ->
        if not (Array.exists (String.equal name) names) then
          report ctx (Member name :: path) Unknown_member
            "This is not a member this object has.")
      (Js.Dict.keys o)

  (* A union's tag, as the JSON text it is, or [absent]'s where it is left
     out. *)
  let tag ctx path o name ~absent : string option =
    match Js.Dict.get o name with
    | Some x -> Some (Js.Json.stringify x)
    | None -> (
        match absent with
        | Some t -> Some t
        | None ->
            report ctx (Member name :: path) Required "This is required.";
            None)

  let unknown_tag ctx path name tags =
    report ctx (Member name :: path) Unknown_word (one_of tags);
    None

  let nullable (read : 'a reader) : 'a option reader =
   fun ctx path j ->
    match Js.Json.classify j with
    | JSONNull -> Some None
    | _ -> Option.map Option.some (read ctx path j)

  (* What a reading ends with: every problem, in the document's order. *)
  let finish ctx result =
    match result () with
    | exception Enough ->
        Error
          (List.rev
             ({
                Problem.at = "";
                code = Too_many_problems;
                message =
                  "This has more problems than the " ^ string_of_int ctx.limit
                  ^ " listed, and was read no further.";
              }
             :: ctx.problems))
    | Some v when List.is_empty ctx.problems -> Ok v
    | None when List.is_empty ctx.problems ->
        Error
          [
            {
              Problem.at = "";
              code = Malformed;
              message = "This could not be read.";
            };
          ]
    | Some _ | None -> Error (List.rev ctx.problems)

  let of_json (read : 'a reader) j =
    let ctx = create () in
    finish ctx (fun () -> read ctx [] j)

  let decode (read : 'a reader) s =
    match Js.Json.parseExn s with
    | j -> of_json read j
    | exception Js.Exn.Error e ->
        Error
          [
            {
              Problem.at = "";
              code = Syntax;
              message =
                "This is not JSON: "
                ^ Option.value (Js.Exn.message e)
                    ~default:"it could not be parsed"
                ^ ".";
            };
          ]

  (* ---------------------------------------------------------------- *)
  (* Writers *)

  let w_any : Js.Json.t writer = fun _ _ j -> Some j
  let w_null : unit writer = fun _ _ () -> Some Js.Json.null
  let w_bool : bool writer = fun _ _ b -> Some (Js.Json.boolean b)

  let w_number ?min ?max ?above ?below ?multiple_of () : float writer =
   fun ctx path f ->
    if not (is_finite f) then (
      report ctx path Malformed "This number is not finite.";
      None)
    else
      Option.map Js.Json.number
        (checked ctx path f
           (number_bounds ~min ~max ~above ~below ~multiple_of f))

  let w_whole ?min ?max ?multiple_of () : float writer =
   fun ctx path f ->
    if not (is_integer f) then (
      report ctx path Unexpected_type
        "This must be a whole number, not a fraction.";
      None)
    else if Float.abs f >= 9007199254740992. then
      past_type ctx path (f < 0.) "a whole number here"
    else
      Option.map Js.Json.number
        (checked ctx path f (whole_bounds ~min ~max ~multiple_of f))

  let w_int ?min ?max ?multiple_of () : int writer =
   fun ctx path n ->
    w_whole
      ?min:(Option.map float_of_int min)
      ?max:(Option.map float_of_int max)
      ?multiple_of:(Option.map float_of_int multiple_of)
      () ctx path (float_of_int n)

  let w_string ?min_length ?max_length () : string writer =
   fun ctx path s ->
    Option.map Js.Json.string
      (checked ctx path s (length_bounds ~min_length ~max_length s))

  let w_kind ?min_length ?max_length (print : 'a -> (string, string) result) :
      'a writer =
   fun ctx path v ->
    match print v with
    | Ok s -> w_string ?min_length ?max_length () ctx path s
    | Error message ->
        report ctx path Malformed message;
        None

  let w_instant ?min_length ?max_length () =
    w_kind ?min_length ?max_length (fun t -> Ok (Instant.to_string t))

  let w_date ?min_length ?max_length () =
    w_kind ?min_length ?max_length (fun (y, m, d) ->
        let yf = float_of_int y
        and mf = float_of_int m
        and df = float_of_int d in
        if
          yf < 0. || yf > 9999. || mf < 1. || mf > 12. || df < 1.
          || df > days_in_month yf mf
        then
          Error
            (string_of_int y ^ "-" ^ string_of_int m ^ "-" ^ string_of_int d
           ^ " is not a date of the years 0000 to 9999.")
        else Ok (four yf ^ "-" ^ two mf ^ "-" ^ two df))

  let w_duration ?min_length ?max_length () =
    w_kind ?min_length ?max_length (fun t -> Ok (Duration.to_string t))

  let w_uuid ?min_length ?max_length ?version () =
    w_kind ?min_length ?max_length (fun u ->
        let s = Uuid.to_string u in
        match version with
        | Some v when Option.is_none (Uuid.of_string_version v s) ->
            Error ("This UUID is not of version " ^ string_of_int v ^ ".")
        | Some _ | None -> Ok s)

  (* A kind the browser holds as its text, checked again on writing. *)
  let w_checked ?min_length ?max_length check message =
    w_kind ?min_length ?max_length (fun s ->
        if check s then Ok s else Error message)

  let w_base64 ?min_length ?max_length () =
    w_checked ?min_length ?max_length (base64_check ~url:false)
      "This must be bytes in base64, padded to a multiple of four."

  let w_base64url ?min_length ?max_length () =
    w_checked ?min_length ?max_length (base64_check ~url:true)
      "This must be bytes in base64url, unpadded."

  let w_uri ?min_length ?max_length () =
    w_checked ?min_length ?max_length url_can_parse
      "This must be a URI with its scheme, like https://example.com/path."

  let w_ipv4 ?min_length ?max_length () =
    w_checked ?min_length ?max_length ipv4_check
      "This must be an IPv4 address, like 192.0.2.1."

  let w_ipv6 ?min_length ?max_length () =
    w_checked ?min_length ?max_length ipv6_check
      "This must be an IPv6 address, like 2001:db8::1."

  let w_enum (word : 'a -> string) : 'a writer =
   fun _ _ v -> Some (Js.Json.string (word v))

  let w_array ?min_items ?max_items (elt : 'a writer) : 'a array writer =
   fun ctx path items ->
    let failed = ref false in
    let out =
      Array.mapi
        (fun i x ->
          match elt ctx (Index i :: path) x with
          | Some j -> j
          | None ->
              failed := true;
              Js.Json.null)
        items
    in
    let within =
      checked ctx path ()
        (count_bounds "item" ~min:min_items ~max:max_items (Array.length items))
    in
    if !failed || Option.is_none within then None else Some (Js.Json.array out)

  (* A tuple's items, each written by the printed code at its index. *)
  let w_tuple (items : Js.Json.t option array) =
    if Array.for_all Option.is_some items then
      Some (Js.Json.array (Array.map (fun j -> Option.get j) items))
    else None

  let w_dict ?min_properties ?max_properties (key : 'k writer)
      (value : 'v writer) : ('k * 'v) array writer =
   fun ctx path items ->
    let failed = ref false in
    let seen = Js.Dict.empty () in
    let out = Js.Dict.empty () in
    Array.iter
      (fun (k, v) ->
        match key ctx path k with
        | None -> failed := true
        | Some kj -> (
            match Js.Json.decodeString kj with
            | None ->
                report ctx path Malformed "This map's name is not text.";
                failed := true
            | Some name -> (
                let at = Member name :: path in
                if Option.is_some (Js.Dict.get seen name) then (
                  report ctx at Repeated_member
                    "This member is given more than once.";
                  failed := true)
                else Js.Dict.set seen name true;
                match value ctx at v with
                | Some j -> Js.Dict.set out name j
                | None -> failed := true)))
      items;
    let within =
      checked ctx path ()
        (count_bounds "member" ~min:min_properties ~max:max_properties
           (Array.length items))
    in
    if !failed || Option.is_none within then None
    else Some (Js.Json.object_ out)

  (* An object's members as the printed code writes them: [None] is a member
     left out, [Some (name, None)] one that could not be written. *)
  let w_object (members : (string * Js.Json.t option) option array) =
    let out = Js.Dict.empty () in
    let failed = ref false in
    Array.iter
      (function
        | None -> ()
        | Some (_, None) -> failed := true
        | Some (name, Some j) -> Js.Dict.set out name j)
      members;
    if !failed then None else Some (Js.Json.object_ out)

  let w_nullable (write : 'a writer) : 'a option writer =
   fun ctx path -> function
    | None -> Some Js.Json.null
    | Some v -> write ctx path v

  let to_json (write : 'a writer) v =
    let ctx = create () in
    finish ctx (fun () -> write ctx [] v)

  let encode (write : 'a writer) v =
    Result.map Js.Json.stringify (to_json write v)
end

(* ---- The types ---- *)

(* One recursive group, since components hold each other. Two may share a
   field's or a word's name, and a value is told apart by its type. *)
[@@@warning "-30"]

(* One input that is not what it should be. *)
type problem = { at : string; (* Where: path.x, query.x, body.x. *) code : string; message : string; }

(* A refusal: the code a client branches on, and a sentence for a person. *)
and refusal = { error : string; (* The code. *) message : string; (* A sentence. *) problems : problem array option; (* For invalid: each input that is not what it should be. *) }

and item_size = | Small | Large

and item = { id : float; name : string; (* What it is called. *) size : item_size; }

and note = { title : string; attached : string option; length : float; }

and said = { text : string; }

and get_items_id_lang = | En | Fr

(* A form: each field its value, a repeated one a list of them. *)
and post_notes_body = { title : string; }

and get_items_id_id = float

and get_items_tag = string array

and get_items_answer = item array

and delete_items_id_id = float

and get_hello_x_name = string

and get_ticks_count = float

and get_ticks_tick_data = float

and get_chat_room_room = string

and get_elsewhere_items_id_id = float

(* ---- Reading ---- *)

let rec read_problem : problem Wire.reader = fun ctx path j -> (fun ctx path j -> match Wire.members ctx path j with | None -> None | Some o -> let m_at = Wire.required (Wire.string ()) ctx path o {js|at|js} in let m_code = Wire.required (Wire.string ()) ctx path o {js|code|js} in let m_message = Wire.required (Wire.string ()) ctx path o {js|message|js} in match (m_at, m_code, m_message) with | (Some m_at, Some m_code, Some m_message) -> Some (({ at = m_at; code = m_code; message = m_message; } : problem)) | _ -> None) ctx path j

and read_refusal : refusal Wire.reader = fun ctx path j -> (fun ctx path j -> match Wire.members ctx path j with | None -> None | Some o -> let m_error = Wire.required (Wire.string ()) ctx path o {js|error|js} in let m_message = Wire.required (Wire.string ()) ctx path o {js|message|js} in let m_problems = Wire.optional (Wire.array read_problem) ctx path o {js|problems|js} in match (m_error, m_message, m_problems) with | (Some m_error, Some m_message, Some m_problems) -> Some (({ error = m_error; message = m_message; problems = m_problems; } : refusal)) | _ -> None) ctx path j

and read_item : item Wire.reader = fun ctx path j -> (fun ctx path j -> match Wire.members ctx path j with | None -> None | Some o -> let m_id = Wire.required (Wire.whole ()) ctx path o {js|id|js} in let m_name = Wire.required (Wire.string ~max_length:(8) ()) ctx path o {js|name|js} in let m_size = Wire.required (Wire.enum [|{js|small|js}; {js|large|js}|] (fun w -> if String.equal w {js|small|js} then Some (Small : item_size) else if String.equal w {js|large|js} then Some (Large : item_size) else None)) ctx path o {js|size|js} in match (m_id, m_name, m_size) with | (Some m_id, Some m_name, Some m_size) -> Some (({ id = m_id; name = m_name; size = m_size; } : item)) | _ -> None) ctx path j

and read_note : note Wire.reader = fun ctx path j -> (fun ctx path j -> match Wire.members ctx path j with | None -> None | Some o -> let m_title = Wire.required (Wire.string ()) ctx path o {js|title|js} in let m_attached = Wire.optional (Wire.string ()) ctx path o {js|attached|js} in let m_length = Wire.required (Wire.whole ()) ctx path o {js|length|js} in match (m_title, m_attached, m_length) with | (Some m_title, Some m_attached, Some m_length) -> Some (({ title = m_title; attached = m_attached; length = m_length; } : note)) | _ -> None) ctx path j

and read_said : said Wire.reader = fun ctx path j -> (fun ctx path j -> match Wire.members ctx path j with | None -> None | Some o -> let m_text = Wire.required (Wire.string ()) ctx path o {js|text|js} in match (m_text) with | (Some m_text) -> Some (({ text = m_text; } : said)) | _ -> None) ctx path j

and read_get_items_id_id : get_items_id_id Wire.reader = fun ctx path j -> (Wire.whole ()) ctx path j

and read_get_items_id_lang : get_items_id_lang Wire.reader = fun ctx path j -> (Wire.enum [|{js|en|js}; {js|fr|js}|] (fun w -> if String.equal w {js|en|js} then Some (En : get_items_id_lang) else if String.equal w {js|fr|js} then Some (Fr : get_items_id_lang) else None)) ctx path j

and read_get_items_tag : get_items_tag Wire.reader = fun ctx path j -> (Wire.array (Wire.string ())) ctx path j

and read_get_items_answer : get_items_answer Wire.reader = fun ctx path j -> (Wire.array read_item) ctx path j

and read_delete_items_id_id : delete_items_id_id Wire.reader = fun ctx path j -> (Wire.whole ()) ctx path j

and read_get_hello_x_name : get_hello_x_name Wire.reader = fun ctx path j -> (Wire.string ()) ctx path j

and read_post_notes_body : post_notes_body Wire.reader = fun ctx path j -> (fun ctx path j -> match Wire.members ctx path j with | None -> None | Some o -> let m_title = Wire.required (Wire.string ()) ctx path o {js|title|js} in match (m_title) with | (Some m_title) -> Some (({ title = m_title; } : post_notes_body)) | _ -> None) ctx path j

and read_get_ticks_count : get_ticks_count Wire.reader = fun ctx path j -> (Wire.whole ()) ctx path j

and read_get_ticks_tick_data : get_ticks_tick_data Wire.reader = fun ctx path j -> (Wire.whole ()) ctx path j

and read_get_chat_room_room : get_chat_room_room Wire.reader = fun ctx path j -> (Wire.string ()) ctx path j

and read_get_elsewhere_items_id_id : get_elsewhere_items_id_id Wire.reader = fun ctx path j -> (Wire.whole ()) ctx path j

(* ---- Writing ---- *)

let rec write_problem : problem Wire.writer = fun ctx path v -> (fun ctx path (v : problem) -> Wire.w_object [|Some ({js|at|js}, (Wire.w_string ()) ctx (Wire.Member {js|at|js} :: path) v.at); Some ({js|code|js}, (Wire.w_string ()) ctx (Wire.Member {js|code|js} :: path) v.code); Some ({js|message|js}, (Wire.w_string ()) ctx (Wire.Member {js|message|js} :: path) v.message)|]) ctx path v

and write_refusal : refusal Wire.writer = fun ctx path v -> (fun ctx path (v : refusal) -> Wire.w_object [|Some ({js|error|js}, (Wire.w_string ()) ctx (Wire.Member {js|error|js} :: path) v.error); Some ({js|message|js}, (Wire.w_string ()) ctx (Wire.Member {js|message|js} :: path) v.message); (match v.problems with None -> None | Some x -> Some ({js|problems|js}, (Wire.w_array write_problem) ctx (Wire.Member {js|problems|js} :: path) x))|]) ctx path v

and write_item : item Wire.writer = fun ctx path v -> (fun ctx path (v : item) -> Wire.w_object [|Some ({js|id|js}, (Wire.w_whole ()) ctx (Wire.Member {js|id|js} :: path) v.id); Some ({js|name|js}, (Wire.w_string ~max_length:(8) ()) ctx (Wire.Member {js|name|js} :: path) v.name); Some ({js|size|js}, (Wire.w_enum (fun (v : item_size) -> match v with | Small -> {js|small|js} | Large -> {js|large|js})) ctx (Wire.Member {js|size|js} :: path) v.size)|]) ctx path v

and write_note : note Wire.writer = fun ctx path v -> (fun ctx path (v : note) -> Wire.w_object [|Some ({js|title|js}, (Wire.w_string ()) ctx (Wire.Member {js|title|js} :: path) v.title); (match v.attached with None -> None | Some x -> Some ({js|attached|js}, (Wire.w_string ()) ctx (Wire.Member {js|attached|js} :: path) x)); Some ({js|length|js}, (Wire.w_whole ()) ctx (Wire.Member {js|length|js} :: path) v.length)|]) ctx path v

and write_said : said Wire.writer = fun ctx path v -> (fun ctx path (v : said) -> Wire.w_object [|Some ({js|text|js}, (Wire.w_string ()) ctx (Wire.Member {js|text|js} :: path) v.text)|]) ctx path v

and write_get_items_id_id : get_items_id_id Wire.writer = fun ctx path v -> (Wire.w_whole ()) ctx path v

and write_get_items_id_lang : get_items_id_lang Wire.writer = fun ctx path v -> (Wire.w_enum (fun (v : get_items_id_lang) -> match v with | En -> {js|en|js} | Fr -> {js|fr|js})) ctx path v

and write_get_items_tag : get_items_tag Wire.writer = fun ctx path v -> (Wire.w_array (Wire.w_string ())) ctx path v

and write_get_items_answer : get_items_answer Wire.writer = fun ctx path v -> (Wire.w_array write_item) ctx path v

and write_delete_items_id_id : delete_items_id_id Wire.writer = fun ctx path v -> (Wire.w_whole ()) ctx path v

and write_get_hello_x_name : get_hello_x_name Wire.writer = fun ctx path v -> (Wire.w_string ()) ctx path v

and write_post_notes_body : post_notes_body Wire.writer = fun ctx path v -> (fun ctx path (v : post_notes_body) -> Wire.w_object [|Some ({js|title|js}, (Wire.w_string ()) ctx (Wire.Member {js|title|js} :: path) v.title)|]) ctx path v

and write_get_ticks_count : get_ticks_count Wire.writer = fun ctx path v -> (Wire.w_whole ()) ctx path v

and write_get_ticks_tick_data : get_ticks_tick_data Wire.writer = fun ctx path v -> (Wire.w_whole ()) ctx path v

and write_get_chat_room_room : get_chat_room_room Wire.writer = fun ctx path v -> (Wire.w_string ()) ctx path v

and write_get_elsewhere_items_id_id : get_elsewhere_items_id_id Wire.writer = fun ctx path v -> (Wire.w_whole ()) ctx path v

(* ---- Each component ---- *)

let decode_problem s = Wire.decode read_problem s
let problem_of_json j = Wire.of_json read_problem j
let encode_problem v = Wire.encode write_problem v
let problem_to_json v = Wire.to_json write_problem v

let decode_refusal s = Wire.decode read_refusal s
let refusal_of_json j = Wire.of_json read_refusal j
let encode_refusal v = Wire.encode write_refusal v
let refusal_to_json v = Wire.to_json write_refusal v

let decode_item s = Wire.decode read_item s
let item_of_json j = Wire.of_json read_item j
let encode_item v = Wire.encode write_item v
let item_to_json v = Wire.to_json write_item v

let decode_note s = Wire.decode read_note s
let note_of_json j = Wire.of_json read_note j
let encode_note v = Wire.encode write_note v
let note_to_json v = Wire.to_json write_note v

let decode_said s = Wire.decode read_said s
let said_of_json j = Wire.of_json read_said j
let encode_said v = Wire.encode write_said v
let said_to_json v = Wire.to_json write_said v

let decode_get_items_id_id s = Wire.decode read_get_items_id_id s
let get_items_id_id_of_json j = Wire.of_json read_get_items_id_id j
let encode_get_items_id_id v = Wire.encode write_get_items_id_id v
let get_items_id_id_to_json v = Wire.to_json write_get_items_id_id v

let decode_get_items_id_lang s = Wire.decode read_get_items_id_lang s
let get_items_id_lang_of_json j = Wire.of_json read_get_items_id_lang j
let encode_get_items_id_lang v = Wire.encode write_get_items_id_lang v
let get_items_id_lang_to_json v = Wire.to_json write_get_items_id_lang v

let decode_get_items_tag s = Wire.decode read_get_items_tag s
let get_items_tag_of_json j = Wire.of_json read_get_items_tag j
let encode_get_items_tag v = Wire.encode write_get_items_tag v
let get_items_tag_to_json v = Wire.to_json write_get_items_tag v

let decode_get_items_answer s = Wire.decode read_get_items_answer s
let get_items_answer_of_json j = Wire.of_json read_get_items_answer j
let encode_get_items_answer v = Wire.encode write_get_items_answer v
let get_items_answer_to_json v = Wire.to_json write_get_items_answer v

let decode_delete_items_id_id s = Wire.decode read_delete_items_id_id s
let delete_items_id_id_of_json j = Wire.of_json read_delete_items_id_id j
let encode_delete_items_id_id v = Wire.encode write_delete_items_id_id v
let delete_items_id_id_to_json v = Wire.to_json write_delete_items_id_id v

let decode_get_hello_x_name s = Wire.decode read_get_hello_x_name s
let get_hello_x_name_of_json j = Wire.of_json read_get_hello_x_name j
let encode_get_hello_x_name v = Wire.encode write_get_hello_x_name v
let get_hello_x_name_to_json v = Wire.to_json write_get_hello_x_name v

let decode_post_notes_body s = Wire.decode read_post_notes_body s
let post_notes_body_of_json j = Wire.of_json read_post_notes_body j
let encode_post_notes_body v = Wire.encode write_post_notes_body v
let post_notes_body_to_json v = Wire.to_json write_post_notes_body v

let decode_get_ticks_count s = Wire.decode read_get_ticks_count s
let get_ticks_count_of_json j = Wire.of_json read_get_ticks_count j
let encode_get_ticks_count v = Wire.encode write_get_ticks_count v
let get_ticks_count_to_json v = Wire.to_json write_get_ticks_count v

let decode_get_ticks_tick_data s = Wire.decode read_get_ticks_tick_data s
let get_ticks_tick_data_of_json j = Wire.of_json read_get_ticks_tick_data j
let encode_get_ticks_tick_data v = Wire.encode write_get_ticks_tick_data v
let get_ticks_tick_data_to_json v = Wire.to_json write_get_ticks_tick_data v

let decode_get_chat_room_room s = Wire.decode read_get_chat_room_room s
let get_chat_room_room_of_json j = Wire.of_json read_get_chat_room_room j
let encode_get_chat_room_room v = Wire.encode write_get_chat_room_room v
let get_chat_room_room_to_json v = Wire.to_json write_get_chat_room_room v

let decode_get_elsewhere_items_id_id s = Wire.decode read_get_elsewhere_items_id_id s
let get_elsewhere_items_id_id_of_json j = Wire.of_json read_get_elsewhere_items_id_id j
let encode_get_elsewhere_items_id_id v = Wire.encode write_get_elsewhere_items_id_id v
let get_elsewhere_items_id_id_to_json v = Wire.to_json write_get_elsewhere_items_id_id v


(* ---- Calling the routes ---- *)

(* What every printed route calls through: the browser's fetch, a request
   checked whole before it goes, and an answer read by what the route says it
   answers. It is Melange over fetch, Js.Json and Js.Dict alone, so a printed
   client needs no library. *)

(** A call to a route, and what can come of it. *)
module Route = struct
  type error =
    [ `Invalid of Problem.t list
      (** an input is not what the route reads: every problem, at the
          parameter's name or the body's own path, and nothing was sent *)
    | `Lost of string
      (** no answer came back: the network failed, or the request was stopped,
          and it may or may not have reached the server *)
    | `Refused of refusal  (** the server's refusal: its code and sentence *)
    | `Unexpected of string
      (** an answer the route does not say it gives: a status it never answers,
          a body its description does not read, or a failure with no refusal in
          it. In words for the console. *) ]

  let error_to_string = function
    | `Invalid problems ->
        "the input is not what the route reads: "
        ^ String.concat "; " (List.map Problem.to_string problems)
    | `Lost message -> message
    | `Refused (r : refusal) -> r.error ^ ": " ^ r.message
    | `Unexpected message -> message

  type response
  type init
  type body
  type form
  type abort_controller
  type signal

  external fetch : string -> init -> response Js.Promise.t = "fetch"

  external init :
    meth:(string[@mel.as "method"]) ->
    headers:string Js.Dict.t ->
    ?body:body ->
    ?signal:signal ->
    unit ->
    init = ""
  [@@mel.obj]

  external abort_controller : unit -> abort_controller = "AbortController"
  [@@mel.new]

  external signal : abort_controller -> signal = "signal" [@@mel.get]
  external abort : abort_controller -> unit = "abort" [@@mel.send]
  external status : response -> int = "status" [@@mel.get]
  external text_of : response -> string Js.Promise.t = "text" [@@mel.send]
  external text_body : string -> body = "%identity"
  external form_body : form -> body = "%identity"
  external form : unit -> form = "FormData" [@@mel.new]
  external append : form -> string -> string -> unit = "append" [@@mel.send]

  external append_file : form -> string -> Js.File.t -> unit = "append"
  [@@mel.send]

  external encode_uri_component : string -> string = "encodeURIComponent"
  external js_string : Js.Promise.error -> string = "String"

  (* A problem in a parameter is reported at its name, as the server
     reports it. *)
  let at name (p : Problem.t) =
    let at =
      match p.at with
      | "" -> name
      | a when String.get a 0 = '[' -> name ^ a
      | a -> name ^ "." ^ a
    in
    { p with at }

  let named name = Result.map_error (List.map (at name))

  (* A parameter's value as the text a path, a query or a header carries: a
     list's items each its own. *)
  let rec texts j =
    match Js.Json.classify j with
    | JSONString s -> [ s ]
    | JSONNumber _ | JSONTrue | JSONFalse -> [ Js.Json.stringify j ]
    | JSONArray items -> List.concat_map texts (Array.to_list items)
    | JSONNull | JSONObject _ -> []

  let literal s = Ok s

  let segment name value =
    Result.map
      (fun j -> String.concat "," (List.map encode_uri_component (texts j)))
      (named name value)

  let query name = function
    | None -> Ok []
    | Some value ->
        Result.map
          (fun j ->
            List.map
              (fun t ->
                encode_uri_component name ^ "=" ^ encode_uri_component t)
              (texts j))
          (named name value)

  let header name = function
    | None -> Ok []
    | Some value ->
        Result.map
          (fun j -> [ (name, String.concat ", " (texts j)) ])
          (named name value)

  type payload = { content_type : string option; body : body option }

  let no_body = Ok { content_type = None; body = None }

  let json = function
    | None -> no_body
    | Some encoded ->
        Result.map
          (fun s ->
            {
              content_type = Some "application/json";
              body = Some (text_body s);
            })
          encoded

  let raw ~content_type = function
    | None -> no_body
    | Some s ->
        Ok { content_type = Some content_type; body = Some (text_body s) }

  (* A form is sent as FormData, which the browser frames as multipart and
     which carries a file beside the fields. *)
  let form fields files =
    Result.map
      (fun j ->
        let f = form () in
        (match Js.Json.classify j with
        | JSONObject members ->
            Array.iter
              (fun (name, value) ->
                List.iter (fun t -> append f name t) (texts value))
              (Js.Dict.entries members)
        | _ -> ());
        List.iter
          (fun (name, each) -> List.iter (append_file f name) each)
          files;
        { content_type = None; body = Some (form_body f) })
      fields

  type 'a answer = { gives : int -> bool; read : string -> ('a, string) result }

  let value statuses decode =
    {
      gives = (fun s -> List.mem s statuses);
      read =
        (fun text ->
          Result.map_error
            (fun problems ->
              "an answer its description does not read: "
              ^ String.concat "; " (List.map Problem.to_string problems))
            (decode text));
    }

  let empty statuses =
    { gives = (fun s -> List.mem s statuses); read = (fun _ -> Ok ()) }

  let text_answer =
    { gives = (fun s -> s >= 200 && s < 300); read = (fun text -> Ok text) }

  let answered answer ~where status text =
    if answer.gives status then
      Result.map_error
        (fun m -> `Unexpected (where ^ " answered " ^ m))
        (answer.read text)
    else if status >= 400 then
      match decode_refusal text with
      | Ok r -> Error (`Refused r)
      | Error _ ->
          Error
            (`Unexpected
               (where ^ " answered " ^ string_of_int status
              ^ " with no refusal in it"))
    else
      Error
        (`Unexpected
           (where ^ " answered " ^ string_of_int status
          ^ ", a status it never gives"))

  let all checked =
    let problems =
      List.concat_map (function Ok _ -> [] | Error ps -> ps) checked
    in
    match problems with
    | [] -> Ok (List.filter_map Result.to_option checked)
    | _ :: _ -> Error problems

  (* A request checked whole: its URL, its fields and its body, or every
     problem its inputs have. *)
  let request ~origin ~path ~query ~headers ~body =
    match (all path, all query, all headers, body) with
    | Ok path, Ok query, Ok headers, Ok (payload : payload) ->
        let query = List.concat query in
        let url =
          origin ^ String.concat "" path
          ^ match query with [] -> "" | q -> "?" ^ String.concat "&" q
        in
        let headers =
          List.concat headers
          @ Option.fold ~none:[]
              ~some:(fun t -> [ ("content-type", t) ])
              payload.content_type
        in
        Ok (url, headers, payload.body)
    | path, query, headers, body ->
        let problems = function Ok _ -> [] | Error ps -> ps in
        Error
          (`Invalid
             (problems path @ problems query @ problems headers @ problems body))

  (* [route] is the route as the server names it, [GET /items/{key}], for
     the words of an error. *)
  let call ?(origin = "") ~route ~meth ~path ~query ~headers ~body answer :
      ('a, error) result Js.Promise.t =
    match request ~origin ~path ~query ~headers ~body with
    | Error e -> Js.Promise.resolve (Error e)
    | Ok (url, headers, body) ->
        Js.Promise.(
          fetch url (init ~meth ~headers:(Js.Dict.fromList headers) ?body ())
          |> then_ (fun r ->
              text_of r |> then_ (fun text -> resolve (Ok (status r, text))))
          |> catch (fun e ->
              resolve (Error (`Lost (route ^ " had no answer: " ^ js_string e))))
          |> then_ (fun got ->
              resolve
                (match got with
                | Ok (status, text) -> answered answer ~where:route status text
                | Error e -> Error e)))

  (* A failure an answer's status says, where the route answers a stream or
     a socket: its refusal, or what it is instead. *)
  let refused ~where status text =
    match decode_refusal text with
    | Ok r when status >= 400 -> Error (`Refused r)
    | Ok _ | Error _ ->
        Error
          (`Unexpected
             (where ^ " answered " ^ string_of_int status
            ^ ", where it answers a stream"))

  (** A route's events as they arrive, read over fetch, so a refusal is read as
      any route's is. Nothing reconnects: a stream that ends is the caller's to
      call again. *)
  module Stream = struct
    type t = {
      controller : abort_controller;
      closed : bool ref;
      ended : (unit, error) result Js.Promise.t;
    }

    let close t =
      if not !(t.closed) then (
        t.closed := true;
        abort t.controller)

    let ended t = t.ended

    (* An event's data, read by its component's decoder. *)
    let json decode wrap data =
      Result.map wrap
        (Result.map_error
           (fun problems ->
             "data its description does not read: "
             ^ String.concat "; " (List.map Problem.to_string problems))
           (decode data))

    type stream
    type reader
    type chunk
    type decoder

    external response_body : response -> stream = "body" [@@mel.get]
    external get_reader : stream -> reader = "getReader" [@@mel.send]
    external read_chunk : reader -> chunk Js.Promise.t = "read" [@@mel.send]
    external is_done : chunk -> bool = "done" [@@mel.get]

    external chunk_value : chunk -> Js.Typed_array.Uint8Array.t = "value"
    [@@mel.get]

    external decoder : unit -> decoder = "TextDecoder" [@@mel.new]

    external decode :
      decoder ->
      Js.Typed_array.Uint8Array.t ->
      (_[@mel.as {json|{"stream":true}|json}]) ->
      string = "decode"
    [@@mel.send]

    (* An event stream's fields as the server writes them and the HTML
       standard reads them: a blank line ends an event, [event:] names it,
       each [data:] line is a line of its data, and a line from [:] is a
       comment. *)
    type parser = {
      mutable pending : string;
      mutable after_cr : bool;
      mutable name : string;
      mutable data : string list;
    }

    let parser () = { pending = ""; after_cr = false; name = ""; data = [] }

    let field p line =
      if String.equal line "" then (
        let data = List.rev p.data and name = p.name in
        p.data <- [];
        p.name <- "";
        match data with
        | [] -> None
        | _ :: _ ->
            Some
              ( (if String.equal name "" then "message" else name),
                String.concat "\n" data ))
      else if String.get line 0 = ':' then None
      else
        let name, value =
          match String.index_opt line ':' with
          | None -> (line, "")
          | Some i ->
              let v = String.sub line (i + 1) (String.length line - i - 1) in
              ( String.sub line 0 i,
                if String.length v > 0 && String.get v 0 = ' ' then
                  String.sub v 1 (String.length v - 1)
                else v )
        in
        (match name with
        | "event" -> p.name <- value
        | "data" -> p.data <- value :: p.data
        | _ -> ());
        None

    (* Each event the text completes, a line ending in CR, LF or both. *)
    let feed p text =
      let events = ref [] and start = ref 0 in
      let text = p.pending ^ text in
      String.iteri
        (fun i ch ->
          if ch = '\n' && p.after_cr && i = !start then start := i + 1
          else if ch = '\n' || ch = '\r' then (
            Option.iter
              (fun e -> events := e :: !events)
              (field p (String.sub text !start (i - !start)));
            start := i + 1);
          p.after_cr <- ch = '\r')
        text;
      p.pending <- String.sub text !start (String.length text - !start);
      List.rev !events

    let call ?(origin = "") ~route ~meth ~path ~query ~headers ~body ~read
        ~on_event () =
      let controller = abort_controller () and closed = ref false in
      let ended =
        match request ~origin ~path ~query ~headers ~body with
        | Error e ->
            closed := true;
            Js.Promise.resolve (Error e)
        | Ok (url, headers, body) ->
            let headers = ("accept", "text/event-stream") :: headers in
            let failed e =
              closed := true;
              abort controller;
              Js.Promise.resolve (Error e)
            in
            let rec pump reader p decoder =
              Js.Promise.then_
                (fun chunk ->
                  if is_done chunk then Js.Promise.resolve (Ok ())
                  else
                    let events = feed p (decode decoder (chunk_value chunk)) in
                    let rec deliver = function
                      | [] -> pump reader p decoder
                      | (name, data) :: rest -> (
                          match read name data with
                          | Ok event ->
                              on_event event;
                              if !closed then Js.Promise.resolve (Ok ())
                              else deliver rest
                          | Error m ->
                              failed
                                (`Unexpected (route ^ " sent " ^ name ^ ", " ^ m))
                          )
                    in
                    deliver events)
                (read_chunk reader)
            in
            Js.Promise.(
              fetch url
                (init ~meth ~headers:(Js.Dict.fromList headers) ?body
                   ~signal:(signal controller) ())
              |> then_ (fun r ->
                  if status r = 200 then
                    pump (get_reader (response_body r)) (parser ()) (decoder ())
                  else
                    text_of r
                    |> then_ (fun text ->
                        resolve (refused ~where:route (status r) text)))
              |> catch (fun e ->
                  resolve
                    (if !closed then Ok ()
                     else
                       Error
                         (`Lost (route ^ " stopped answering: " ^ js_string e)))))
      in
      { controller; closed; ended }
  end

  (** A WebSocket to a route: what the server sends handed over as it comes,
      typed by the route, and what is sent typed and checked before it goes. *)
  module Socket = struct
    type websocket
    type message_event
    type close_event
    type frame = Text of string | Binary of Js.Typed_array.ArrayBuffer.t

    type 'client t = {
      ws : websocket option;
      write : 'client -> (frame, Problem.t list) result;
      mutable queued : frame list;  (** what was sent before it opened *)
      closed : bool ref;
      ended : (unit, error) result Js.Promise.t;
    }

    external websocket : string -> string array -> websocket = "WebSocket"
    [@@mel.new]

    external set_binary_type : websocket -> string -> unit = "binaryType"
    [@@mel.set]

    external ready_state : websocket -> int = "readyState" [@@mel.get]
    external send_text : websocket -> string -> unit = "send" [@@mel.send]

    external send_binary : websocket -> Js.Typed_array.ArrayBuffer.t -> unit
      = "send"
    [@@mel.send]

    external close_ws : websocket -> unit = "close" [@@mel.send]

    external set_on_open : websocket -> (unit -> unit) -> unit = "onopen"
    [@@mel.set]

    external set_on_message : websocket -> (message_event -> unit) -> unit
      = "onmessage"
    [@@mel.set]

    external set_on_close : websocket -> (close_event -> unit) -> unit
      = "onclose"
    [@@mel.set]

    external message_data : message_event -> Js.Json.t = "data" [@@mel.get]
    external as_text : Js.Json.t -> string = "%identity"
    external as_bytes : Js.Json.t -> Js.Typed_array.ArrayBuffer.t = "%identity"
    external close_code : close_event -> int = "code" [@@mel.get]
    external close_reason : close_event -> string = "reason" [@@mel.get]
    external new_url : string -> string -> Js.Json.t = "URL" [@@mel.new]
    external url_protocol : Js.Json.t -> string = "protocol" [@@mel.get]

    external set_url_protocol : Js.Json.t -> string -> unit = "protocol"
    [@@mel.set]

    external url_href : Js.Json.t -> string = "href" [@@mel.get]
    external page : string = "href" [@@mel.scope "location"]

    (* An origin's http as ws and https as wss; the page's own where none is
       given. *)
    let ws_url ~origin url =
      let u = new_url url (if String.equal origin "" then page else origin) in
      set_url_protocol u
        (if String.equal (url_protocol u) "https:" then "wss:" else "ws:");
      url_href u

    let put ws = function
      | Text s -> send_text ws s
      | Binary b -> send_binary ws b

    let send t message =
      match (t.ws, t.write message) with
      | _, Error problems -> Error (`Invalid problems)
      | None, Ok _ -> Error (`Lost "the socket was never opened")
      | Some ws, Ok frame -> (
          match ready_state ws with
          | 0 ->
              t.queued <- t.queued @ [ frame ];
              Ok ()
          | 1 ->
              put ws frame;
              Ok ()
          | _ -> Error (`Lost "the socket is closed"))

    let close t =
      t.closed := true;
      Option.iter close_ws t.ws

    let ended t = t.ended
    let json_out encode v = Result.map (fun s -> Text s) (encode v)
    let text_out s = Ok (Text s)
    let binary_out b = Ok (Binary b)

    let json_in decode = function
      | Text s ->
          Result.map_error
            (fun problems ->
              "a message its description does not read: "
              ^ String.concat "; " (List.map Problem.to_string problems))
            (decode s)
      | Binary _ -> Error "bytes, where it sends JSON"

    let text_in = function
      | Text s -> Ok s
      | Binary _ -> Error "bytes, where it sends text"

    let binary_in = function
      | Binary b -> Ok b
      | Text _ -> Error "text, where it sends bytes"

    let call ?(origin = "") ~route ~path ~query ?subprotocol ~write ~read
        ~on_message () =
      match request ~origin:"" ~path ~query ~headers:[] ~body:no_body with
      | Error e ->
          {
            ws = None;
            write;
            queued = [];
            closed = ref true;
            ended = Js.Promise.resolve (Error e);
          }
      | Ok (url, _, _) ->
          let ws =
            websocket (ws_url ~origin url)
              (match subprotocol with Some p -> [| p |] | None -> [||])
          in
          set_binary_type ws "arraybuffer";
          let closed = ref false and failure = ref None in
          let ended =
            Js.Promise.make (fun ~resolve ~reject:_ ->
                set_on_close ws (fun e ->
                    let result =
                      match !failure with
                      | Some f -> Error f
                      | None ->
                          if !closed || close_code e = 1000 then Ok ()
                          else
                            Error
                              (`Lost
                                 (route ^ " closed with "
                                 ^ string_of_int (close_code e)
                                 ^
                                 match close_reason e with
                                 | "" -> ""
                                 | r -> ": " ^ r))
                    in
                    (resolve result [@u])))
          in
          let t = { ws = Some ws; write; queued = []; closed; ended } in
          set_on_open ws (fun () ->
              List.iter (put ws) t.queued;
              t.queued <- []);
          set_on_message ws (fun e ->
              let data = message_data e in
              let frame =
                if Js.typeof data = "string" then Text (as_text data)
                else Binary (as_bytes data)
              in
              match read frame with
              | Ok message -> on_message message
              | Error m ->
                  failure := Some (`Unexpected (route ^ " sent " ^ m));
                  close t);
          t
  end
end

(* ---- Each route ---- *)

(** An item, by its id *)
let get_items_id ?origin ~id ?lang () =
  Route.call ?origin ~route:{js|GET /items/{id}|js} ~meth:{js|GET|js}
    ~path:[ Route.literal {js|/items/|js}; Route.segment {js|id|js} (get_items_id_id_to_json id) ]
    ~query:[ Route.query {js|lang|js} (Option.map get_items_id_lang_to_json lang) ]
    ~headers:[]
    ~body:Route.no_body
    (Route.value [ 200 ] decode_item)

let get_items ?origin ?tag () =
  Route.call ?origin ~route:{js|GET /items|js} ~meth:{js|GET|js}
    ~path:[ Route.literal {js|/items|js} ]
    ~query:[ Route.query {js|tag|js} (Option.map get_items_tag_to_json tag) ]
    ~headers:[]
    ~body:Route.no_body
    (Route.value [ 200 ] decode_get_items_answer)

let post_items ?origin ~body () =
  Route.call ?origin ~route:{js|POST /items|js} ~meth:{js|POST|js}
    ~path:[ Route.literal {js|/items|js} ]
    ~query:[]
    ~headers:[]
    ~body:(Route.json (Some (encode_item body)))
    (Route.value [ 201 ] decode_item)

let delete_items_id ?origin ~id () =
  Route.call ?origin ~route:{js|DELETE /items/{id}|js} ~meth:{js|DELETE|js}
    ~path:[ Route.literal {js|/items/|js}; Route.segment {js|id|js} (delete_items_id_id_to_json id) ]
    ~query:[]
    ~headers:[]
    ~body:Route.no_body
    (Route.empty [ 204 ])

let get_hello ?origin ~x_name () =
  Route.call ?origin ~route:{js|GET /hello|js} ~meth:{js|GET|js}
    ~path:[ Route.literal {js|/hello|js} ]
    ~query:[]
    ~headers:[ Route.header {js|x-name|js} (Some (get_hello_x_name_to_json x_name)) ]
    ~body:Route.no_body
    Route.text_answer

let post_notes ?origin ~body ?attachment () =
  Route.call ?origin ~route:{js|POST /notes|js} ~meth:{js|POST|js}
    ~path:[ Route.literal {js|/notes|js} ]
    ~query:[]
    ~headers:[]
    ~body:(Route.form (post_notes_body_to_json body) [ ({js|attachment|js}, Option.to_list attachment) ])
    (Route.value [ 200 ] decode_note)

let put_echo ?origin ~body () =
  Route.call ?origin ~route:{js|PUT /echo|js} ~meth:{js|PUT|js}
    ~path:[ Route.literal {js|/echo|js} ]
    ~query:[]
    ~headers:[]
    ~body:(Route.raw ~content_type:{js|text/plain|js} (Some body))
    Route.text_answer

type get_ticks_event = Tick of get_ticks_tick_data | Line of string

let get_ticks ?origin ~count ~on_event () =
  Route.Stream.call ?origin ~route:{js|GET /ticks|js} ~meth:{js|GET|js}
    ~path:[ Route.literal {js|/ticks|js} ]
    ~query:[ Route.query {js|count|js} (Some (get_ticks_count_to_json count)) ]
    ~headers:[]
    ~body:Route.no_body
    ~read:(fun name data ->
      if String.equal name {js|tick|js} then Route.Stream.json decode_get_ticks_tick_data (fun x -> (Tick x : get_ticks_event)) data
      else if String.equal name {js|line|js} then Ok (Line data : get_ticks_event)
      else Error "an event it never sends")
    ~on_event ()

let get_chat_room ?origin ~room ~on_message () =
  Route.Socket.call ?origin ~route:{js|GET /chat/{room}|js}
    ~path:[ Route.literal {js|/chat/|js}; Route.segment {js|room|js} (get_chat_room_room_to_json room) ]
    ~query:[]
    ~write:(Route.Socket.json_out encode_said)
    ~read:(Route.Socket.json_in decode_said)
    ~on_message ()

let get_elsewhere_items_id ?origin ~id () =
  Route.call ?origin ~route:{js|GET /elsewhere/items/{id}|js} ~meth:{js|GET|js}
    ~path:[ Route.literal {js|/elsewhere/items/|js}; Route.segment {js|id|js} (get_elsewhere_items_id_id_to_json id) ]
    ~query:[]
    ~headers:[]
    ~body:Route.no_body
    Route.text_answer

