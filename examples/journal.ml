(* The resource mcp_journal serves: a journal an intent, numbered lines from 1,
   appended and never changed, read from a line on. *)

open Spindle.Syntax

type t = { lock : Eio.Mutex.t; journals : (string, string list) Hashtbl.t }
(* each journal newest line first *)

let create () = { lock = Eio.Mutex.create (); journals = Hashtbl.create 16 }

let append t id line =
  Eio.Mutex.use_rw ~protect:true t.lock (fun () ->
      let lines = Option.value (Hashtbl.find_opt t.journals id) ~default:[] in
      Hashtbl.replace t.journals id (line :: lines))

(* The lines from [from] on, oldest first; [None] for a journal never begun. *)
let lines t id ~from =
  Eio.Mutex.use_ro t.lock (fun () ->
      Option.map
        (fun newest_first ->
          List.filteri (fun i _ -> i + 1 >= from) (List.rev newest_first))
        (Hashtbl.find_opt t.journals id))

let begun t id = Eio.Mutex.use_ro t.lock (fun () -> Hashtbl.mem t.journals id)

(* What the template reads: the journals, which the server holds. *)
let journals : t Spindle.Dep.t = Spindle.Dep.of_resource "journals"

(* A line a content, so a reader counts what it was given. A read with no
   [from] answers no line: it is what a listen makes to check a caller may
   read the journal, and should cost nothing. *)
let journal =
  Spindle_mcp.template "haf://intents/{id}/journal{?from}" ~name:"journal"
    ~doc:"An intent's journal, one JSON event a line, from line [from] on."
    ~mime:"application/json" ~ttl_ms:0
    Spindle_mcp.Template.(
      let+ id = required "id" Wiretype.string
      and+ from = optional "from" (Wiretype.int_bounded ~min:1 ()) in
      (id, from))
    (let+ journals = journals in
     fun (id, from) ->
       match from with
       | None ->
           if begun journals id then Ok [] else Error Spindle.Refusal.not_found
       | Some from -> (
           match lines journals id ~from with
           | Some lines -> Ok (List.map (fun l -> Spindle_mcp.Text l) lines)
           | None -> Error Spindle.Refusal.not_found))
