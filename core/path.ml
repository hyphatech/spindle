module R = Path_repr

type ('a, 'kind) t = ('a, 'kind) Path_repr.t
type 'a param = ('a, [ `Param ]) t
type path = (unit, [ `Path ]) t

let param ?or_not_found name codec =
  R.Param
    { name; codec; or_not_found = Option.is_some or_not_found; rest = false }

let str ?or_not_found name = param ?or_not_found name Codec.string
let int ?or_not_found name = param ?or_not_found name Codec.int
let int64 ?or_not_found name = param ?or_not_found name Codec.int64

let rest name =
  R.Param { name; codec = R.rest_codec; or_not_found = false; rest = true }

let spec : type a. a param -> a R.spec = function R.Param p -> p
let name p = (spec p).name
let root = R.Path []
let s l = R.Path [ R.Fixed l ]
let ( / ) a b = R.Path (R.parts_of a @ R.parts_of b)

let pattern p =
  "/"
  ^ String.concat "/"
      (List.map
         (function
           | R.Fixed l -> l
           | R.Variable p when p.rest -> "{" ^ p.name ^ "*}"
           | R.Variable p -> "{" ^ p.name ^ "}")
         (R.parts_of p))

type arg = Arg : 'a param * 'a -> arg

let arg p v = Arg (p, v)
let encode = R.encode
let arg_name (Arg (p, _)) = name p
let print_arg (Arg (p, v)) = Codec.print (spec p).codec v

let url p args =
  let ( let* ) = Result.bind in
  let names = List.map arg_name args in
  let rec check_unique = function
    | [] -> Ok ()
    | n :: rest when List.exists (String.equal n) rest ->
        Error (Printf.sprintf "%s: %s is given twice" (pattern p) n)
    | _ :: rest -> check_unique rest
  in
  let* () = check_unique names in
  let params =
    List.filter_map
      (function R.Variable q -> Some q.name | R.Fixed _ -> None)
      (R.parts_of p)
  in
  let* () =
    match
      List.find_opt (fun n -> not (List.exists (String.equal n) params)) names
    with
    | Some n -> Error (Printf.sprintf "%s has no parameter %s" (pattern p) n)
    | None -> Ok ()
  in
  let rec build acc = function
    | [] -> Ok ("/" ^ String.concat "/" (List.rev acc))
    | R.Fixed l :: rest -> build (encode l :: acc) rest
    | R.Variable q :: rest -> (
        match
          List.find_opt (fun a -> String.equal (arg_name a) q.name) args
        with
        (* A rest prints already encoded, its segments joined by the only
           slashes in it, and may be no segment at all. *)
        | Some a when q.rest -> (
            match print_arg a with
            | "" -> build acc rest
            | v when List.exists (String.equal "") (String.split_on_char '/' v)
              ->
                Error
                  (Printf.sprintf
                     "%s: %s has an empty segment, which no URL can hold"
                     (pattern p) q.name)
            | v -> build (v :: acc) rest)
        | Some a -> (
            match print_arg a with
            | "" ->
                Error
                  (Printf.sprintf
                     "%s: %s printed as nothing, which no URL can hold"
                     (pattern p) q.name)
            | v -> build (encode v :: acc) rest)
        | None ->
            Error (Printf.sprintf "%s: no argument for %s" (pattern p) q.name))
  in
  build [] (R.parts_of p)
