module Text = Wiretype.Text
include Spindle_http.Log

type format = Pretty | Json

(* ------------------------------------------------------------------ *)
(* Lines *)

let level_name = function
  | Logs.App -> "app"
  | Logs.Error -> "error"
  | Logs.Warning -> "warn"
  | Logs.Info -> "info"
  | Logs.Debug -> "debug"

let now_with_ms () =
  let t = Unix.gettimeofday () in
  (t, int_of_float ((t -. Float.of_int (int_of_float t)) *. 1000.))

(* Digit by digit: a seven-argument format string cost a line nearly as much
   as all its fields. *)
let add_iso_time b =
  let t, ms = now_with_ms () in
  let tm = Unix.gmtime t in
  let two_digits n =
    Buffer.add_char b (Char.chr (48 + (n / 10)));
    Buffer.add_char b (Char.chr (48 + (n mod 10)))
  in
  let year = tm.tm_year + 1900 in
  Buffer.add_char b '"';
  two_digits (year / 100);
  two_digits (year mod 100);
  Buffer.add_char b '-';
  two_digits (tm.tm_mon + 1);
  Buffer.add_char b '-';
  two_digits tm.tm_mday;
  Buffer.add_char b 'T';
  two_digits tm.tm_hour;
  Buffer.add_char b ':';
  two_digits tm.tm_min;
  Buffer.add_char b ':';
  two_digits tm.tm_sec;
  Buffer.add_char b '.';
  Buffer.add_char b (Char.chr (48 + (ms / 100)));
  two_digits (ms mod 100);
  Buffer.add_string b "Z\""

let local_clock_time () =
  let t, ms = now_with_ms () in
  let tm = Unix.localtime t in
  Printf.sprintf "%02d:%02d:%02d.%03d" tm.tm_hour tm.tm_min tm.tm_sec ms

(* An integer past 2^53 is written as a string: a reader holding numbers as
   doubles would round it. *)
let add_json_value b : value -> unit = function
  | `String s -> Text.string b s
  | `Int n when n >= -(1 lsl 53) && n <= 1 lsl 53 ->
      Buffer.add_string b (string_of_int n)
  | `Int n -> Text.string b (string_of_int n)
  | `Float f -> Text.number b f
  | `Bool x -> Buffer.add_string b (if x then "true" else "false")

(* Written straight into the buffer: building a JSON value to encode was
   most of what a line allocated. *)
let add_json_line b ~level ~src ~msg ~id ~trace ~span ~fields =
  let member k add v =
    Buffer.add_char b ',';
    Text.string b k;
    Buffer.add_char b ':';
    add b v
  in
  Buffer.add_string b {|{"timestamp":|};
  add_iso_time b;
  member "level" Text.string (level_name level);
  member "logger.name" Text.string src;
  member "message" Text.string msg;
  Option.iter (member "request_id" Text.string) id;
  Option.iter (member "trace_id" Text.string) trace;
  Option.iter (member "span_id" Text.string) span;
  List.iter (fun (k, v) -> member k add_json_value v) fields;
  Buffer.add_char b '}'

let add_pretty_line b ~level ~src ~msg ~id ~trace:_ ~span:_ ~fields =
  Buffer.add_string b (local_clock_time ());
  Buffer.add_char b ' ';
  Buffer.add_string b (Printf.sprintf "%-5s" (level_name level));
  Buffer.add_char b ' ';
  Buffer.add_string b src;
  (match id with
  | Some id -> Buffer.add_string b (" [" ^ id ^ "]")
  | None -> ());
  Buffer.add_char b ' ';
  Buffer.add_string b msg;
  List.iter
    (fun (k, v) -> Buffer.add_string b (Format.asprintf "  %s=%a" k pp_value v))
    fields

(* ------------------------------------------------------------------ *)
(* The default sink: stderr *)

(* Each domain appends its lines to a buffer of its own, and a writer domain
   writes every domain's. The writer is a domain rather than a thread: a
   thread shares the runtime lock of the domain that made it, and every read
   and write that domain's server made would wait on it. *)
type domain_lines = {
  lock : Mutex.t;
  mutable pending : Buffer.t;  (** appended to under [lock] *)
  mutable spare : Buffer.t;  (** the writer's, exchanged for [pending] *)
  mutable ended : bool;  (** its domain has; under [lock] *)
  mutable registered : bool;  (** in [registered]; under [lock] *)
}

let registered = Atomic.make []

let rec update_registered f =
  let all = Atomic.get registered in
  if not (Atomic.compare_and_set registered all (f all)) then
    update_registered f

let wake_lock = Mutex.create ()
let wake = Condition.create ()
let woken = ref false

let wake_writer () =
  Mutex.protect wake_lock (fun () ->
      woken := true;
      Condition.signal wake)

(* Held for a whole pass, so the exit's flush never interleaves with the
   writer's. *)
let pass_lock = Mutex.create ()

(* Each pass carries a millisecond of lines: woken for each line, the writer
   cost a third of a core under load. *)
let pass_interval_s = 0.001

(* A domain's buffer leaves [registered] once the domain has ended and its
   lines are written, so a program that starts domains as it goes keeps none
   of theirs; one that logs after that, from an [at_exit] of its own, is put
   back. Both changes are made under the domain's lock. *)
let domain_lines =
  Domain.DLS.new_key (fun () ->
      let d =
        {
          lock = Mutex.create ();
          pending = Buffer.create 4_096;
          spare = Buffer.create 4_096;
          ended = false;
          registered = true;
        }
      in
      update_registered (List.cons d);
      Domain.at_exit (fun () ->
          Mutex.protect d.lock (fun () -> d.ended <- true);
          wake_writer ());
      d)

let append_line line =
  let d = Domain.DLS.get domain_lines in
  Mutex.lock d.lock;
  if not d.registered then begin
    d.registered <- true;
    update_registered (List.cons d)
  end;
  let was_empty = Buffer.length d.pending = 0 in
  Buffer.add_buffer d.pending line;
  Buffer.add_char d.pending '\n';
  Mutex.unlock d.lock;
  if was_empty then wake_writer ()

(* Under [pass_lock]. A domain waits on it only for an exchange of two
   buffers. *)
let write_pass () =
  List.iter
    (fun d ->
      Mutex.lock d.lock;
      let lines = d.pending in
      d.pending <- d.spare;
      d.spare <- lines;
      if d.ended && d.registered then begin
        d.registered <- false;
        update_registered (List.filter (fun other -> other != d))
      end;
      Mutex.unlock d.lock;
      Buffer.output_buffer Stdlib.stderr lines;
      Buffer.clear lines)
    (Atomic.get registered);
  flush Stdlib.stderr

let writer () =
  while true do
    Mutex.protect wake_lock (fun () ->
        while not !woken do
          Condition.wait wake wake_lock
        done;
        woken := false);
    Mutex.protect pass_lock write_pass;
    Unix.sleepf pass_interval_s
  done

let writer_started = Atomic.make false

let start_writer () =
  if Atomic.compare_and_set writer_started false true then begin
    ignore (Domain.spawn writer : unit Domain.t);
    at_exit (fun () -> Mutex.protect pass_lock write_pass)
  end

(* ------------------------------------------------------------------ *)
(* The reporter *)

type sink = Stderr | Out of (string -> unit)

(* An [out] of the program's may not be safe from two domains at once. *)
let out_lock = Mutex.create ()

(* Reused for each line: a formatter and a buffer made per line allocated
   as much as the rest of a request. Claimed for a whole line; a line that
   finds it claimed -- a printer that logs, another thread of the domain --
   makes its own. A printer that raises leaves it claimed, and the domain's
   later lines make their own. *)
type scratch = {
  message : Buffer.t;
  formatter : Format.formatter;
  line : Buffer.t;
  claimed : bool Atomic.t;
}

let scratch =
  Domain.DLS.new_key (fun () ->
      let message = Buffer.create 256 in
      {
        message;
        formatter = Format.formatter_of_buffer message;
        line = Buffer.create 512;
        claimed = Atomic.make false;
      })

let reporter ~format ~sink =
  let report src level ~over k msgf =
    msgf (fun ?header:_ ?tags fmt ->
        let fields =
          match tags with
          | None -> []
          | Some tags -> Option.value (Logs.Tag.find fields tags) ~default:[]
        in
        let write line msg =
          (match format with
          | Pretty -> add_pretty_line
          | Json -> add_json_line)
            line ~level ~src:(Logs.Src.name src) ~msg ~id:(request_id ())
            ~trace:(trace_id ()) ~span:(span_id ()) ~fields;
          match sink with
          | Stderr -> append_line line
          | Out out ->
              let line = Buffer.contents line in
              Mutex.protect out_lock (fun () -> out line)
        in
        let s = Domain.DLS.get scratch in
        if Atomic.compare_and_set s.claimed false true then begin
          Buffer.clear s.message;
          Format.kfprintf
            (fun formatter ->
              Format.pp_print_flush formatter ();
              let msg = Buffer.contents s.message in
              Buffer.clear s.line;
              Fun.protect
                ~finally:(fun () -> Atomic.set s.claimed false)
                (fun () -> write s.line msg);
              over ();
              k ())
            s.formatter fmt
        end
        else
          Format.kasprintf
            (fun msg ->
              write (Buffer.create 512) msg;
              over ();
              k ())
            fmt)
  in
  { Logs.report }

(* The sources that log what crossed the wire, credentials included: a level
   set for every source raises them no further than [Warning], so turning
   them up means naming them. *)
let wire_sources = [ "tls.tracing"; "handshake" ]

let at_most_warning = function
  | Some (Logs.Debug | Logs.Info) -> Some Logs.Warning
  | l -> l

let setup ?format ?(level = Some Logs.Info) ?(sources = []) ?out () =
  let sink =
    match out with
    | Some out -> Out out
    | None ->
        start_writer ();
        Stderr
  in
  let format =
    match format with
    | Some f -> f
    | None -> if Unix.isatty Unix.stderr then Pretty else Json
  in
  (* So {!raised} has a stack; domains spawned later inherit it. *)
  Printexc.record_backtrace true;
  (* Not Logs' own reporter mutex, which would be held while every line is
     formatted. *)
  Logs.set_reporter (reporter ~format ~sink);
  Logs.set_level level;
  List.iter
    (fun src ->
      let name = Logs.Src.name src in
      match List.assoc_opt name sources with
      | Some l -> Logs.Src.set_level src l
      | None ->
          if List.exists (String.equal name) wire_sources then
            Logs.Src.set_level src (at_most_warning level))
    (Logs.Src.list ())

let level_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "warn" -> Ok (Some Logs.Warning)
  | "off" -> Ok None
  | other -> (
      match Logs.level_of_string other with
      | Ok l -> Ok l
      | Error _ -> Error (Printf.sprintf "%S is not a log level" s))

(* A variable exported but never set arrives as an empty string, which is no
   setting. *)
let non_blank = function
  | Some s when not (String.equal (String.trim s) "") -> Some (String.trim s)
  | Some _ | None -> None

let configure ~levels ~format =
  let ( let* ) = Result.bind in
  let levels = non_blank levels and format = non_blank format in
  let* format =
    match Option.map String.lowercase_ascii format with
    | None -> Ok None
    | Some "pretty" -> Ok (Some Pretty)
    | Some "json" -> Ok (Some Json)
    | Some other ->
        Error (Printf.sprintf "%S is not a log format: pretty or json" other)
  in
  let* level, sources =
    match levels with
    | None -> Ok (Some Logs.Info, [])
    | Some spec ->
        List.fold_left
          (fun acc part ->
            let* level, sources = acc in
            match String.index_opt part '=' with
            | None ->
                let* l = level_of_string part in
                Ok (l, sources)
            | Some i ->
                let name = String.trim (String.sub part 0 i) in
                let* l =
                  level_of_string
                    (String.sub part (i + 1) (String.length part - i - 1))
                in
                Ok (level, (name, l) :: sources))
          (Ok (Some Logs.Info, []))
          (List.filter
             (fun p -> not (String.equal (String.trim p) ""))
             (String.split_on_char ',' spec))
  in
  setup ?format ~level ~sources ();
  Ok ()
