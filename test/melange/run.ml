(* The printed client in the browser's runtime, calling the test application
   served at the origin named on its command line: each route's function, what
   it answers read as the route's type, and each way a call fails. Run by Bun,
   one call after another; it exits 1 when any case fails. *)

external argv : string array = "argv" [@@mel.scope "process"]
external exit : int -> unit = "exit" [@@mel.scope "process"]
external file : string array -> string -> Js.File.t = "File" [@@mel.new]

let origin = Array.get argv (Array.length argv - 1)
let failures = ref 0

let fail name found =
  incr failures;
  Js.log ("FAIL " ^ name ^ "\n  found: " ^ found)

let show = function
  | Ok _ -> "an answer"
  | Error e -> Client.Route.error_to_string e

let check called judge () =
  Js.Promise.then_ (fun got -> Js.Promise.resolve (judge got)) (called ())

(* Each case calls, and says what it found where it is wrong. *)
let cases =
  [
    ( "a path parameter, and an answer read as its type",
      check
        (fun () -> Client.get_items_id ~origin ~id:1. ())
        (function
          | Ok ({ id = 1.; name = "pen"; size = Small } : Client.item) -> Ok ()
          | got -> Error (show got)) );
    ( "an optional query parameter, an enum",
      check
        (fun () -> Client.get_items_id ~origin ~id:1. ~lang:Fr ())
        (function
          | Ok ({ name = "stylo"; _ } : Client.item) -> Ok ()
          | got -> Error (show got)) );
    ( "a list in the query, each item its own",
      check
        (fun () -> Client.get_items ~origin ~tag:[| "a"; "b c" |] ())
        (function
          | Ok [| { name = "a"; _ }; { name = "b c"; _ } |] -> Ok ()
          | got -> Error (show got)) );
    ( "a JSON body, and the status the route answers with",
      check
        (fun () ->
          Client.post_items ~origin
            ~body:{ id = 0.; name = "cup"; size = Large }
            ())
        (function
          | Ok ({ id = 2.; name = "cup"; _ } : Client.item) -> Ok ()
          | got -> Error (show got)) );
    ( "a body that breaks its bounds is never sent",
      check
        (fun () ->
          Client.post_items ~origin
            ~body:{ id = 0.; name = "much too long"; size = Large }
            ())
        (function
          | Error
              (`Invalid
                 [ ({ at = "name"; code = Too_long; _ } : Client.Problem.t) ])
            ->
              Ok ()
          | got -> Error (show got)) );
    ( "an empty answer",
      check
        (fun () -> Client.delete_items_id ~origin ~id:1. ())
        (function Ok () -> Ok () | got -> Error (show got)) );
    ( "a header, and a text answer",
      check
        (fun () -> Client.get_hello ~origin ~x_name:"Ada" ())
        (function Ok "Good morning, Ada." -> Ok () | got -> Error (show got)) );
    ( "a form, with a file",
      check
        (fun () ->
          Client.post_notes ~origin ~body:{ title = "list" }
            ~attachment:(file [| "milk" |] "list.txt")
            ())
        (function
          | Ok
              ({ title = "list"; attached = Some "list.txt"; length = 4. } :
                Client.note) ->
              Ok ()
          | got -> Error (show got)) );
    ( "a form, without its optional file",
      check
        (fun () -> Client.post_notes ~origin ~body:{ title = "list" } ())
        (function
          | Ok ({ attached = None; length = 0.; _ } : Client.note) -> Ok ()
          | got -> Error (show got)) );
    ( "a raw body",
      check
        (fun () -> Client.put_echo ~origin ~body:"as it is" ())
        (function Ok "as it is" -> Ok () | got -> Error (show got)) );
    ( "the server's refusal",
      check
        (fun () -> Client.get_items_id ~origin ~id:2. ())
        (function
          | Error (`Refused ({ error = "not_found"; _ } : Client.refusal)) ->
              Ok ()
          | got -> Error (show got)) );
    ( "an answer the route does not give",
      check
        (fun () ->
          Client.get_items_id ~origin:(origin ^ "/elsewhere") ~id:1. ())
        (function Error (`Unexpected _) -> Ok () | got -> Error (show got)) );
    ( "a stream's events, each its type, until it ends",
      fun () ->
        let got = ref [] in
        let stream =
          Client.get_ticks ~origin ~count:2.
            ~on_event:(fun e -> got := e :: !got)
            ()
        in
        Js.Promise.then_
          (fun ended ->
            Js.Promise.resolve
              (match (ended, List.rev !got) with
              | Ok (), [ Tick 1.; Tick 2.; Line "done\nfor now" ] -> Ok ()
              | Ok (), events ->
                  Error (string_of_int (List.length events) ^ " events")
              | (Error _ as e), _ -> Error (show e)))
          (Client.Route.Stream.ended stream) );
    ( "a stream closed by its caller ends well",
      fun () ->
        let got = ref 0 in
        let rec stream =
          lazy
            (Client.get_ticks ~origin ~count:1000.
               ~on_event:(fun _ ->
                 incr got;
                 Client.Route.Stream.close (Lazy.force stream))
               ())
        in
        Js.Promise.then_
          (fun ended ->
            Js.Promise.resolve
              (match ended with
              | Ok () when !got = 1 -> Ok ()
              | Ok () -> Error (string_of_int !got ^ " events")
              | Error _ as e -> Error (show e)))
          (Client.Route.Stream.ended (Lazy.force stream)) );
    ( "a stream the server refuses",
      fun () ->
        Js.Promise.then_
          (fun ended ->
            Js.Promise.resolve
              (match ended with
              | Error (`Refused ({ error = "not_found"; _ } : Client.refusal))
                ->
                  Ok ()
              | got -> Error (show got)))
          (Client.Route.Stream.ended
             (Client.get_ticks ~origin:(origin ^ "/nowhere") ~count:1.
                ~on_event:ignore ())) );
    ( "a socket: messages sent before it opens, and each answer typed",
      fun () ->
        let got = ref [] in
        let rec socket =
          lazy
            (Client.get_chat_room ~origin ~room:"r"
               ~on_message:(fun (m : Client.said) ->
                 got := m.text :: !got;
                 if List.length !got = 2 then
                   Client.Route.Socket.close (Lazy.force socket))
               ())
        in
        let sent =
          ( Client.Route.Socket.send (Lazy.force socket) { text = "hi" },
            Client.Route.Socket.send (Lazy.force socket) { text = "again" } )
        in
        Js.Promise.then_
          (fun ended ->
            Js.Promise.resolve
              (match (sent, ended, List.rev !got) with
              | (Ok (), Ok ()), Ok (), [ "r: hi"; "r: again" ] -> Ok ()
              | _, (Error _ as e), _ -> Error (show e)
              | _, _, texts -> Error (String.concat ", " texts)))
          (Client.Route.Socket.ended (Lazy.force socket)) );
    ( "no answer at all",
      check
        (fun () -> Client.get_items_id ~origin:"http://127.0.0.1:1" ~id:1. ())
        (function Error (`Lost _) -> Ok () | got -> Error (show got)) );
  ]

let () =
  let run previous (name, case) =
    Js.Promise.then_
      (fun () ->
        Js.Promise.then_
          (fun result ->
            (match result with Ok () -> () | Error found -> fail name found);
            Js.Promise.resolve ())
          (case ()))
      previous
  in
  let all = List.fold_left run (Js.Promise.resolve ()) cases in
  ignore
    (Js.Promise.then_
       (fun () ->
         Js.log
           (string_of_int (List.length cases - !failures)
           ^ " of "
           ^ string_of_int (List.length cases)
           ^ " cases hold");
         exit (if !failures = 0 then 0 else 1);
         Js.Promise.resolve ())
       all)
