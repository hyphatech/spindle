(* The application the printed client is written from and called against: a
   route of every kind a function calls -- a JSON answer and an empty one,
   text, a JSON body, a form with a file, a raw body, a stream of events and
   a socket -- and inputs of every place: a path's, a query's, a list of
   them, an enum, a header. *)

module Ws = Spindle.Websocket
open Spindle.Syntax

let ( let* ) = Result.bind

type size = Small | Large

let size =
  Wiretype.enum ~kind:"size"
    (function Small -> "small" | Large -> "large")
    [ Small; Large ]

type item = { id : int; name : string; size : size }

let item =
  Wiretype.Object.map ~kind:"item" (fun id name size -> { id; name; size })
  |> Wiretype.Object.mem "id" Wiretype.int ~enc:(fun i -> i.id)
  |> Wiretype.Object.mem "name" (Wiretype.string_bounded ~max_length:8 ())
       ~doc:"What it is called." ~enc:(fun i -> i.name)
  |> Wiretype.Object.mem "size" size ~enc:(fun i -> i.size)
  |> Wiretype.Object.finish

type note = { title : string; attached : string option; length : int }

let note =
  Wiretype.Object.map ~kind:"note" (fun title attached length ->
      { title; attached; length })
  |> Wiretype.Object.mem "title" Wiretype.string ~enc:(fun n -> n.title)
  |> Wiretype.Object.opt_mem "attached" Wiretype.string ~enc:(fun n ->
      n.attached)
  |> Wiretype.Object.mem "length" Wiretype.int ~enc:(fun n -> n.length)
  |> Wiretype.Object.finish

type lang = En | Fr

let lang =
  Wiretype.enum ~kind:"lang" (function En -> "en" | Fr -> "fr") [ En; Fr ]

type ticks

let tick : (int, ticks) Spindle.Event.kind =
  Spindle.Event.json "tick" Wiretype.int

let line : (string, ticks) Spindle.Event.kind = Spindle.Event.text "line"

type said = { text : string }

let said =
  Wiretype.Object.map ~kind:"said" (fun text -> { text })
  |> Wiretype.Object.mem "text" Wiretype.string ~enc:(fun s -> s.text)
  |> Wiretype.Object.finish

let chat = Ws.(protocol ~client:(json said) ~server:(json said) ())
let room = Spindle.Path.string "room"
let id = Spindle.Path.int "id"
let pen = { id = 1; name = "pen"; size = Small }

let routes =
  [
    Spindle.get ~summary:"An item, by its id"
      Spindle.Path.(s "items" / id)
      (Spindle.Returns.json item)
      (let+ id = Spindle.param id
       and+ lang = Spindle.Query.optional "lang" lang in
       match (id, lang) with
       | 1, (None | Some En) -> Ok pen
       | 1, Some Fr -> Ok { pen with name = "stylo" }
       | _ -> Error Spindle.Refusal.not_found);
    Spindle.get
      Spindle.Path.(s "items")
      (Spindle.Returns.json (Wiretype.list item))
      (let+ tags = Spindle.Query.list "tag" Wiretype.string in
       Ok (List.mapi (fun i name -> { id = i + 1; name; size = Large }) tags));
    Spindle.post
      Spindle.Path.(s "items")
      (Spindle.Returns.json ~status:`Created item)
      (let+ i = Spindle.json item in
       Ok { i with id = 2 });
    Spindle.delete
      Spindle.Path.(s "items" / id)
      (Spindle.Returns.empty ())
      (let+ _ = Spindle.param id in
       Ok ());
    Spindle.get
      Spindle.Path.(s "hello")
      Spindle.Returns.text
      (let+ name = Spindle.Header.required "x-name" Wiretype.string in
       Ok ("Good morning, " ^ name ^ "."));
    Spindle.post
      Spindle.Path.(s "notes")
      (Spindle.Returns.json note)
      (let+ title = Spindle.Form.required "title" Wiretype.string
       and+ file = Spindle.Form.File.optional "attachment" in
       Ok
         {
           title;
           attached =
             Option.bind file (fun (f : Spindle.Form.File.t) -> f.filename);
           length =
             Option.fold ~none:0
               ~some:(fun (f : Spindle.Form.File.t) -> String.length f.content)
               file;
         });
    Spindle.put
      Spindle.Path.(s "echo")
      Spindle.Returns.text
      (let+ body =
         Spindle.Dep.of_body ~content_types:[ "text/plain" ] (fun body ->
             Ok body)
       in
       Ok body);
    Spindle.get
      Spindle.Path.(s "ticks")
      (Spindle.Returns.events Spindle.Event.[ declare tick; declare line ])
      (let+ count = Spindle.Query.required "count" Wiretype.int in
       Ok
         (fun send ->
           let rec from i =
             if i > count then send (Spindle.Event.make line "done\nfor now")
             else
               let* () = send (Spindle.Event.make tick i) in
               from (i + 1)
           in
           from 1));
    Spindle.get
      Spindle.Path.(s "chat" / room)
      (Spindle.Returns.websocket chat)
      (let+ room = Spindle.param room in
       Ok
         (fun ws ->
           let rec echo () =
             let* m = Ws.receive ws in
             let* () = Ws.send ws { text = room ^ ": " ^ m.text } in
             echo ()
           in
           echo ()));
    (* What a client reads as an item where it called through the wrong
       origin: text, which no item is. *)
    Spindle.get
      Spindle.Path.(s "elsewhere" / s "items" / id)
      Spindle.Returns.text
      (let+ _ = Spindle.param id in
       Ok "not an item");
  ]

let app =
  match Spindle.App.make routes with Ok a -> a | Error m -> invalid_arg m
