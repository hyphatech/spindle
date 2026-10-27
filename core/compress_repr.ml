(* A compression policy, made by [Compress.make] and applied by [App]. *)

module Media_type = Spindle_http.Media_type

type policy = { min_bytes : int; level : int; types : string list }
type t = policy option

(* A tag names one representation, so a gzipped one's is the tag marked. *)
let mark = "-gzip"
let gzip_tag (t : Spindle_http.Etag.t) = { t with opaque = t.opaque ^ mark }

(* The route's tag a marked one was made from. *)
let unmarked (t : Spindle_http.Etag.t) =
  if String.ends_with ~suffix:mark t.opaque then
    Some
      {
        t with
        opaque =
          String.sub t.opaque 0 (String.length t.opaque - String.length mark);
      }
  else None

let compressible t content_type =
  match Option.map Media_type.parse content_type with
  | Some (Ok m) -> List.exists (fun p -> Media_type.matches p m) t.types
  | Some (Error _) | None -> false
