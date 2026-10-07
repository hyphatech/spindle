let http = Logs.Src.create "spindle.http" ~doc:"Requests and their answers"

type value =
  [ `String of string | `Int of int | `Float of float | `Bool of bool ]

let pp_value ppf : value -> unit = function
  | `String s -> Format.pp_print_string ppf s
  | `Int n -> Format.pp_print_int ppf n
  | `Float f -> Format.fprintf ppf "%g" f
  | `Bool b -> Format.pp_print_bool ppf b

let fields =
  Logs.Tag.def "fields" ~doc:"Structured fields" (fun ppf l ->
      Format.pp_print_list ~pp_sep:Format.pp_print_space
        (fun ppf (k, v) -> Format.fprintf ppf "%s=%a" k pp_value v)
        ppf l)

let tags l = Logs.Tag.add fields l Logs.Tag.empty

let raised ex bt =
  let stack = String.trim (Printexc.raw_backtrace_to_string bt) in
  [
    ("error.kind", `String (Printexc.exn_slot_name ex));
    ("error.message", `String (Printexc.to_string ex));
  ]
  @ if String.equal stack "" then [] else [ ("error.stack", `String stack) ]

(* ------------------------------------------------------------------ *)
(* The request a fiber runs for, which is [Context]'s *)

let request_id () =
  Option.map (fun (c : Context.t) -> c.id) (Context.current ())

let trace_id () =
  Option.map (fun (c : Context.t) -> c.trace_id) (Context.current ())

let span_id () =
  Option.map (fun (c : Context.t) -> c.span_id) (Context.current ())

let fresh_id = Context.fresh_id

let is_hex s =
  String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

(* W3C Trace Context §3.2: version-traceid-parentid-flags in lowercase hex,
   no id all zeros, never version ff. A later version is read as its first
   four parts, as §4.3 asks; only the sampled flag is kept. *)
let parse_traceparent v =
  let n = String.length v in
  if n < 55 then None
  else
    let version = String.sub v 0 2
    and trace_id = String.sub v 3 32
    and parent = String.sub v 36 16
    and flags = String.sub v 53 2 in
    let well_formed =
      v.[2] = '-'
      && v.[35] = '-'
      && v.[52] = '-'
      && if String.equal version "00" then n = 55 else n = 55 || v.[55] = '-'
    in
    if
      well_formed && is_hex version
      && (not (String.equal version "ff"))
      && is_hex trace_id
      && (not (Context.is_all_zeros trace_id))
      && is_hex parent
      && (not (Context.is_all_zeros parent))
      && is_hex flags
    then
      let sampled =
        match int_of_string_opt ("0x" ^ flags) with
        | Some f -> f land 1 = 1
        | None -> false
      in
      Some (trace_id, parent, sampled)
    else None

(* W3C Trace Context §3.3.1.5: at least 512 characters are passed on. A
   longer one is dropped rather than cut, since nothing here reads where its
   entries end. *)
let tracestate_limit = 512

let with_request_id ?traceparent ?tracestate ?trace id f =
  let trace_id, parent_id, sampled =
    match Option.bind traceparent parse_traceparent with
    | Some (trace_id, parent, sampled) -> (trace_id, Some parent, sampled)
    | None ->
        ( Context.fresh_hex 32,
          None,
          match trace with Some e -> Context.sample_root e | None -> false )
  in
  let tracestate =
    match (parent_id, tracestate) with
    | Some _, Some s when String.length s <= tracestate_limit -> Some s
    | Some _, (Some _ | None) | None, _ -> None
  in
  let span_id = Context.fresh_hex 16 in
  let span =
    match trace with
    | Some e when sampled ->
        Some
          (Context.start_span e ~trace_id ~span_id ~parent_id
             ~kind:Context.Server ~attributes:[] "request")
    | Some _ | None -> None
  in
  let c = { Context.id; trace_id; span_id; sampled; tracestate; span } in
  match span with
  | Some u -> Context.bind c (fun () -> Context.with_span u f)
  | None -> Context.bind c f

(* The call's own span id where it is recorded, so the server it reaches is
   its child; otherwise a fresh id. *)
let traceparent () =
  Option.map
    (fun (c : Context.t) ->
      Printf.sprintf "00-%s-%s-%s" c.trace_id
        (match c.span with Some _ -> c.span_id | None -> Context.fresh_hex 16)
        (if c.sampled then "01" else "00"))
    (Context.current ())

let tracestate () = Option.bind (Context.current ()) (fun c -> c.tracestate)

let carry f =
  match Context.current () with
  | None -> f
  | Some c -> fun () -> Context.bind c f
