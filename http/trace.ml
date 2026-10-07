type value = Context.value
type kind = Context.kind = Server | Client | Internal
type status = Context.status = Unset | Error of string

type span = Context.span = {
  trace_id : string;
  span_id : string;
  parent_id : string option;
  name : string;
  kind : kind;
  start_ns : int;
  end_ns : int;
  attributes : (string * value) list;
  status : status;
}

type exporter = Context.exporter

let exporter ?(ratio = 1.) ~clock ~mono_clock record =
  {
    Context.record;
    ratio;
    wall_ns =
      (fun () -> Int64.to_int (Int64.of_float (Eio.Time.now clock *. 1e9)));
    mono_ns =
      (fun () ->
        Int64.to_int (Mtime.to_uint64_ns (Eio.Time.Mono.now mono_clock)));
  }

type recording = Context.recording option

(* A child of the fiber's span, bound for [f]; outside a recorded trace [f]
   runs as it is. *)
let within ?(kind = Internal) ?(attributes = []) name f =
  match Context.current () with
  | Some ({ span = Some parent; _ } as c) ->
      let span_id = Context.fresh_hex 16 in
      let u =
        Context.start_span parent.exporter ~trace_id:c.trace_id ~span_id
          ~parent_id:(Some c.span_id) ~kind ~attributes name
      in
      Context.bind { c with span_id; span = Some u } (fun () ->
          Context.with_span u (fun () -> f (Some u)))
  | Some { span = None; _ } | None -> f None

let span ?kind ?attributes name f =
  within ?kind ?attributes name (fun _ -> f ())

let current () = match Context.current () with Some c -> c.span | None -> None

let rename u name =
  Option.iter (fun (u : Context.recording) -> u.span <- { u.span with name }) u

let add u attributes =
  Option.iter (fun u -> Context.add_attributes u attributes) u

let fail u how =
  Option.iter
    (fun (u : Context.recording) ->
      u.span <- { u.span with status = Error how })
    u
