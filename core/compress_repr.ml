(* A compression policy, made by [Compress.make] and applied by [App]. *)

module Media_type = Spindle_http.Media_type

type t = { min_bytes : int; level : int; types : string list }

let never : unit Meta.key = Meta.key ()

(* [type/subtype], [type/*], or [type/*+suffix], compared without case. *)
let type_matches (m : Media_type.t) pattern =
  match String.split_on_char '/' (String.lowercase_ascii pattern) with
  | [ ty; "*" ] -> String.equal ty m.type_
  | [ ty; sub ] when String.starts_with ~prefix:"*+" sub ->
      String.equal ty m.type_
      && String.ends_with
           ~suffix:(String.sub sub 1 (String.length sub - 1))
           m.subtype
  | [ ty; sub ] -> String.equal ty m.type_ && String.equal sub m.subtype
  | _ -> false

let compressible t content_type =
  match Option.map Media_type.parse content_type with
  | Some (Ok m) -> List.exists (type_matches m) t.types
  | Some (Error _) | None -> false
