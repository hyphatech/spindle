(* A series is a cell per domain, found through a table of the domain's own,
   so counting takes no lock and touches no other domain's memory. A
   family's lock is taken only when a domain first counts a combination of
   label values, and when a reading lists the cells. *)

type 'c family = {
  name : string;  (** as exposed *)
  help : string;
  labels : string list;  (** as exposed *)
  domain_cells : (string list, 'c) Hashtbl.t Domain.DLS.key;
  lock : Mutex.t;
  mutable all_cells : (string list * 'c) list;
      (** every domain's, newest first *)
}

type counter = int Atomic.t family
type gauge = int Atomic.t family
type cells = { counts : int Atomic.t array; sum : float Atomic.t }
type histogram = { family : cells family; bounds : float array }

type sampled = {
  s_name : string;
  s_help : string;
  s_labels : string list;
  mutable readers : (unit -> (string list * float) list) list;
  warned : bool Atomic.t;  (** of a series with the wrong number of values *)
}

type entry =
  | Counter of counter
  | Gauge of gauge
  | Histogram of histogram
  | Sampled of sampled

type t = { lock : Mutex.t; mutable entries : entry list  (** newest first *) }

let create () = { lock = Mutex.create (); entries = [] }

(* ------------------------------------------------------------------ *)
(* Names *)

let prometheus_name = String.map (function '.' -> '_' | c -> c)

let is_valid_name ~colon s =
  String.length s > 0
  && (match s.[0] with
    | 'a' .. 'z' | 'A' .. 'Z' | '_' -> true
    | ':' -> colon
    | _ -> false)
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
         | ':' -> colon
         | _ -> false)
       s

let exposed_name ~unit name =
  let n =
    prometheus_name name
    ^ match unit with Some u -> "_" ^ prometheus_name u | None -> ""
  in
  if not (is_valid_name ~colon:true n) then
    invalid_arg (Printf.sprintf "Spindle.Metrics: %S is no metric name" name);
  n

let label_names labels =
  List.map
    (fun l ->
      let n = prometheus_name l in
      (* [le] is a histogram's bucket, and a name under [__] Prometheus's. *)
      if
        (not (is_valid_name ~colon:false n))
        || String.equal n "le"
        || String.starts_with ~prefix:"__" n
      then invalid_arg (Printf.sprintf "Spindle.Metrics: %S is no label" l);
      n)
    labels

let name_of = function
  | Counter f | Gauge f -> f.name
  | Histogram h -> h.family.name
  | Sampled s -> s.s_name

let register t entry =
  Mutex.protect t.lock (fun () ->
      if
        List.exists
          (fun e -> String.equal (name_of e) (name_of entry))
          t.entries
      then
        invalid_arg
          (Printf.sprintf "Spindle.Metrics: %s is registered twice"
             (name_of entry));
      t.entries <- entry :: t.entries)

let family ~help ~unit ~labels name =
  {
    name = exposed_name ~unit name;
    help = Option.value help ~default:"";
    labels = label_names (Option.value labels ~default:[]);
    domain_cells = Domain.DLS.new_key (fun () -> Hashtbl.create 8);
    lock = Mutex.create ();
    all_cells = [];
  }

(* This domain's cell for those values, made and listed the first time. *)
let cell (f : _ family) make values =
  if List.compare_lengths values f.labels <> 0 then
    invalid_arg
      (Printf.sprintf "Spindle.Metrics: %s takes %d label values, not %d" f.name
         (List.length f.labels) (List.length values));
  let cells = Domain.DLS.get f.domain_cells in
  match Hashtbl.find_opt cells values with
  | Some c -> c
  | None ->
      let c = make () in
      Hashtbl.add cells values c;
      Mutex.protect f.lock (fun () -> f.all_cells <- (values, c) :: f.all_cells);
      c

(* ------------------------------------------------------------------ *)
(* Counting *)

let counter t ?help ?unit ?labels name =
  let f = family ~help ~unit ~labels name in
  register t (Counter f);
  f

let inc ?(by = 1) c values =
  if by < 0 then
    invalid_arg
      (Printf.sprintf "Spindle.Metrics: counter %s cannot go down by %d" c.name
         (-by));
  ignore
    (Atomic.fetch_and_add (cell c (fun () -> Atomic.make 0) values) by : int)

let gauge t ?help ?unit ?labels name =
  let f = family ~help ~unit ~labels name in
  register t (Gauge f);
  f

let add g values n =
  ignore
    (Atomic.fetch_and_add (cell g (fun () -> Atomic.make 0) values) n : int)

let sampled t ?help ?unit ?labels name read =
  let s_name = exposed_name ~unit name
  and s_labels = label_names (Option.value labels ~default:[]) in
  Mutex.protect t.lock (fun () ->
      match
        List.find_opt (fun e -> String.equal (name_of e) s_name) t.entries
      with
      | Some (Sampled s) when List.equal String.equal s.s_labels s_labels ->
          s.readers <- s.readers @ [ read ]
      | Some (Counter _ | Gauge _ | Histogram _ | Sampled _) ->
          invalid_arg
            (Printf.sprintf "Spindle.Metrics: %s is registered twice" s_name)
      | None ->
          t.entries <-
            Sampled
              {
                s_name;
                s_help = Option.value help ~default:"";
                s_labels;
                readers = [ read ];
                warned = Atomic.make false;
              }
            :: t.entries)

(* OpenTelemetry's bounds for an HTTP request's duration, in seconds. *)
let default_buckets =
  [
    0.005; 0.01; 0.025; 0.05; 0.075; 0.1; 0.25; 0.5; 0.75; 1.; 2.5; 5.; 7.5; 10.;
  ]

let histogram t ?help ?unit ?labels ?(buckets = default_buckets) name =
  let family = family ~help ~unit ~labels name in
  let bounds = Array.of_list buckets in
  let increasing = ref true in
  Array.iteri
    (fun i b ->
      if (not (Float.is_finite b)) || (i > 0 && b <= bounds.(i - 1)) then
        increasing := false)
    bounds;
  if not !increasing then
    invalid_arg
      (Printf.sprintf "Spindle.Metrics: %s's buckets are not finite and rising"
         family.name);
  let h = { family; bounds } in
  register t (Histogram h);
  h

let rec add_float a v =
  let old = Atomic.get a in
  if not (Atomic.compare_and_set a old (old +. v)) then add_float a v

(* A count per bucket, the last past every bound; they are summed into
   Prometheus's cumulative counts when read. *)
let observe h values v =
  let c =
    cell h.family
      (fun () ->
        {
          counts =
            Array.init (Array.length h.bounds + 1) (fun _ -> Atomic.make 0);
          sum = Atomic.make 0.;
        })
      values
  in
  let n = Array.length h.bounds in
  let rec bucket_index i =
    if i < n && v > h.bounds.(i) then bucket_index (i + 1) else i
  in
  Atomic.incr c.counts.(bucket_index 0);
  add_float c.sum v

(* ------------------------------------------------------------------ *)
(* Prometheus's text format, 0.0.4 *)

let format_number f =
  if Float.is_nan f then "NaN"
  else if Float.equal f Float.infinity then "+Inf"
  else if Float.equal f Float.neg_infinity then "-Inf"
  else if Float.is_integer f && Float.abs f < 1e15 then Printf.sprintf "%.0f" f
  else
    let s = Printf.sprintf "%.15g" f in
    if Float.equal (float_of_string s) f then s else Printf.sprintf "%.17g" f

let escape ~quote s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '"' when quote -> Buffer.add_string b "\\\""
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(* An empty value is no label, as Prometheus reads one. *)
let add_series_name b name names values extra =
  Buffer.add_string b name;
  let pairs =
    List.filter
      (fun (_, v) -> not (String.equal v ""))
      (List.combine names values)
    @ extra
  in
  (match pairs with
  | [] -> ()
  | _ :: _ ->
      Buffer.add_char b '{';
      Buffer.add_string b
        (String.concat ","
           (List.map
              (fun (k, v) ->
                Printf.sprintf "%s=\"%s\"" k (escape ~quote:true v))
              pairs));
      Buffer.add_char b '}');
  Buffer.add_char b ' '

let add_metadata b ~name ~help ~kind =
  if not (String.equal help "") then
    Buffer.add_string b
      (Printf.sprintf "# HELP %s %s\n" name (escape ~quote:false help));
  Buffer.add_string b (Printf.sprintf "# TYPE %s %s\n" name kind)

(* Every domain's cells for each combination of values, in the order first
   counted. *)
let series_of (f : _ family) =
  let all = Mutex.protect f.lock (fun () -> List.rev f.all_cells) in
  let order = ref [] and by = Hashtbl.create 16 in
  List.iter
    (fun (values, c) ->
      match Hashtbl.find_opt by values with
      | Some cs -> Hashtbl.replace by values (c :: cs)
      | None ->
          order := values :: !order;
          Hashtbl.replace by values [ c ])
    all;
  List.map
    (fun values ->
      (values, Option.value (Hashtbl.find_opt by values) ~default:[]))
    (List.rev !order)

let sum_cells cells = List.fold_left (fun n c -> n + Atomic.get c) 0 cells

let add_entry b = function
  | Counter f ->
      let name = f.name ^ "_total" in
      add_metadata b ~name ~help:f.help ~kind:"counter";
      List.iter
        (fun (values, cells) ->
          add_series_name b name f.labels values [];
          Buffer.add_string b (string_of_int (sum_cells cells));
          Buffer.add_char b '\n')
        (series_of f)
  | Gauge f ->
      add_metadata b ~name:f.name ~help:f.help ~kind:"gauge";
      List.iter
        (fun (values, cells) ->
          add_series_name b f.name f.labels values [];
          Buffer.add_string b (string_of_int (sum_cells cells));
          Buffer.add_char b '\n')
        (series_of f)
  | Sampled s ->
      add_metadata b ~name:s.s_name ~help:s.s_help ~kind:"gauge";
      List.iter
        (fun read ->
          List.iter
            (fun (values, v) ->
              (* A raise here would fail the whole page while it is read, so
                 the series is left out and said once. *)
              if List.compare_lengths values s.s_labels = 0 then begin
                add_series_name b s.s_name s.s_labels values [];
                Buffer.add_string b (format_number v);
                Buffer.add_char b '\n'
              end
              else if Atomic.compare_and_set s.warned false true then
                Logs.warn ~src:Log.http (fun m ->
                    m "%s: a series with %d label values, not %d, left out"
                      s.s_name (List.length values) (List.length s.s_labels)))
            (read ()))
        s.readers
  | Histogram h ->
      let f = h.family in
      add_metadata b ~name:f.name ~help:f.help ~kind:"histogram";
      List.iter
        (fun (values, cells) ->
          let n = Array.length h.bounds and running = ref 0 in
          for i = 0 to n do
            running :=
              !running
              + List.fold_left (fun k c -> k + Atomic.get c.counts.(i)) 0 cells;
            add_series_name b (f.name ^ "_bucket") f.labels values
              [ ("le", if i < n then format_number h.bounds.(i) else "+Inf") ];
            Buffer.add_string b (string_of_int !running);
            Buffer.add_char b '\n'
          done;
          add_series_name b (f.name ^ "_sum") f.labels values [];
          Buffer.add_string b
            (format_number
               (List.fold_left (fun s c -> s +. Atomic.get c.sum) 0. cells));
          Buffer.add_char b '\n';
          add_series_name b (f.name ^ "_count") f.labels values [];
          Buffer.add_string b (string_of_int !running);
          Buffer.add_char b '\n')
        (series_of f)

let exposition t =
  let entries = Mutex.protect t.lock (fun () -> List.rev t.entries) in
  let b = Buffer.create 4096 in
  List.iter (add_entry b) entries;
  Buffer.contents b

(* Scraped every few seconds, so its access line is at debug. *)
let debug_access = Meta.(empty |> add access Logs.Debug)

let routes ?(at = Path.s "metrics") ?(guard = Dep.return ()) t =
  [
    Route_repr.get ~summary:"What the server counts, as Prometheus reads it"
      ~meta:debug_access at Returns.text
      (Dep.map (fun () -> Ok (exposition t)) guard);
  ]
