let ( let* ) = Result.bind

type app =
  Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> (Spindle.App.t, string) result

(* Made on a switch of its own and only described; no request reaches
   it. *)
let with_app env (app : app) f =
  Eio.Switch.run @@ fun sw ->
  let* a = app env ~sw in
  f a

let generated ~title = function
  | `Openapi -> fun a -> Spindle.Openapi.document ~title a
  | `Zod ->
      fun a ->
        Spindle.Zod.module_
          ~header:
            (Printf.sprintf
               "Generated from %s's routes. Do not edit: change the routes, \
                and generate it again."
               title)
          a

let write_or_print output text =
  match output with
  | None ->
      print_string text;
      Ok ()
  | Some path -> (
      match
        Out_channel.with_open_bin path (fun oc ->
            Out_channel.output_string oc text)
      with
      | () ->
          print_endline path;
          Ok ()
      | exception Sys_error m -> Error m)

let generate env app ~title ~output what =
  with_app env app (fun a ->
      let* text =
        Result.map_error (String.concat "\n") (generated ~title what a)
      in
      write_or_print output text)

(* Loose descriptions are always reported, and fail only with [strict]. *)
let check env app ~title ~openapi ~zod ~strict =
  with_app env app (fun a ->
      let matches_committed what path =
        let* text =
          Result.map_error (String.concat "\n") (generated ~title what a)
        in
        match In_channel.with_open_bin path In_channel.input_all with
        | committed when String.equal committed text -> Ok ()
        | _ ->
            Error
              (Printf.sprintf
                 "%s is not what the routes make: generate it again" path)
        | exception Sys_error _ -> Error (path ^ " is missing: generate it")
      in
      let loose = Spindle.Openapi.report a in
      List.iter (fun l -> prerr_endline ("loose: " ^ l)) loose;
      (* Each file is checked, so one run names every file to generate. *)
      let stale =
        List.filter_map
          (fun (what, path) ->
            Result.fold
              ~ok:(fun () -> None)
              ~error:Option.some
              (matches_committed what path))
          [ (`Openapi, openapi); (`Zod, zod) ]
      in
      match (stale, strict, loose) with
      | _ :: _, _, _ -> Error (String.concat "\n" stale)
      | [], true, _ :: _ ->
          Error
            (Printf.sprintf "%d places are described loosely"
               (List.length loose))
      | [], true, [] | [], false, _ -> Ok ())

(* ------------------------------------------------------------------ *)
(* The command line *)

module Arg = Cmdliner.Arg
module Cmd = Cmdliner.Cmd
open Cmdliner.Term.Syntax

let exit_code = function
  | Ok () -> 0
  | Error m ->
      prerr_endline m;
      1

(* What [exit_code] and [Cmd.eval'] exit with, and nothing else: cmdliner's
   own list names 123, which only a term of results exits with. *)
let exits =
  [
    Cmd.Exit.info Cmd.Exit.ok ~doc:"on success.";
    Cmd.Exit.info 1
      ~doc:
        "when it could not do what was asked: a committed file that is not \
         what the routes make, or an app that could not be made; the reason is \
         on standard error.";
    Cmd.Exit.info Cmd.Exit.cli_error ~doc:"on command line parsing errors.";
    Cmd.Exit.info Cmd.Exit.internal_error ~doc:"on unexpected internal errors.";
  ]

let run ~name ?(title = name) ~app:make env =
  let output =
    Arg.value
    @@ Arg.opt (Arg.some Arg.string) None
    @@ Arg.info [ "o"; "output" ] ~docv:"FILE"
         ~doc:"Where it is written; printed when not given."
  in
  let file name ~doc =
    Arg.required
    @@ Arg.opt (Arg.some Arg.string) None
    @@ Arg.info [ name ] ~docv:"FILE" ~doc
  in
  let strict =
    Arg.value @@ Arg.flag
    @@ Arg.info [ "strict" ]
         ~doc:"Fail when anything is described loosely, not only report it."
  in
  let write what =
    let+ output = output in
    exit_code (generate env make ~title ~output what)
  in
  let check =
    let+ openapi = file "openapi" ~doc:"The committed document."
    and+ zod = file "zod" ~doc:"The committed module."
    and+ strict = strict in
    exit_code (check env make ~title ~openapi ~zod ~strict)
  in
  let api =
    Cmd.group
      (Cmd.info "api" ~exits ~doc:"The HTTP API, described from the routes.")
      [
        Cmd.v
          (Cmd.info "openapi" ~exits ~doc:"Write the OpenAPI 3.2 document.")
          (write `Openapi);
        Cmd.v
          (Cmd.info "zod" ~exits
             ~doc:"Write the TypeScript module of zod schemas.")
          (write `Zod);
        Cmd.v
          (Cmd.info "check" ~exits
             ~doc:
               "Write nothing; fail if either committed file is not what the \
                routes make, and report every place described loosely.")
          check;
      ]
  in
  exit (Cmd.eval' (Cmd.group (Cmd.info name ~exits) [ api ]))
