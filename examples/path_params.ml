(* Typed path parameters, answered as text and as JSON.

   A parameter is made once, named, and read with [Spindle.param] in every route
   whose path has it; the name is where a segment that does not parse is
   reported -- /users/abc is a 400 at [path.user_id]. *)

open Spindle.Syntax

(* --8<-- [start:routes] *)
(* A codec of the application's own: any type with a parser and a printer. *)
let int64 =
  Spindle.Codec.custom ~kind:"int64" ~parse:Int64.of_string_opt
    ~print:Int64.to_string ()

let user_id = Spindle.Path.param "user_id" int64
let name = Spindle.Path.str "name"

(* The answer's description is derived from its record, so a name holding a
   quote is still one JSON string. *)
type user = { user_id : string; name : string } [@@deriving wiretype]

(* The endpoints take values, not a request: the route below says where each
   value comes from. *)
let user_text id = Ok (Printf.sprintf "User %Ld" id)
let user_answer id name = Ok { user_id = Int64.to_string id; name }

let routes =
  [
    Spindle.get
      Spindle.Path.(s "users" / user_id)
      Spindle.Returns.text
      (let+ id = Spindle.param user_id in
       user_text id);
    Spindle.get
      Spindle.Path.(s "api" / s "users" / user_id / name)
      (Spindle.Returns.json user_json)
      (let+ id = Spindle.param user_id and+ name = Spindle.param name in
       user_answer id name);
  ]
(* --8<-- [end:routes] *)

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
