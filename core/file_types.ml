(* The one table [Static] and [Files] take a file's Content-Type from. *)

(* The extensions a site ships, and a directory of uploads holds. *)
let content_types =
  [
    (".html", "text/html; charset=utf-8");
    (".js", "text/javascript; charset=utf-8");
    (".mjs", "text/javascript; charset=utf-8");
    (".css", "text/css; charset=utf-8");
    (".json", "application/json");
    (".map", "application/json");
    (".xml", "application/xml");
    (".txt", "text/plain; charset=utf-8");
    (".svg", "image/svg+xml");
    (".png", "image/png");
    (".jpg", "image/jpeg");
    (".jpeg", "image/jpeg");
    (".webp", "image/webp");
    (".avif", "image/avif");
    (".ico", "image/x-icon");
    (".woff2", "font/woff2");
    (".woff", "font/woff");
    (".ttf", "font/ttf");
    (".gif", "image/gif");
    (".csv", "text/csv; charset=utf-8");
    (".pdf", "application/pdf");
    (".wasm", "application/wasm");
    (".zip", "application/zip");
    (".mp4", "video/mp4");
    (".webm", "video/webm");
    (".mp3", "audio/mpeg");
    (".ogg", "audio/ogg");
    (".wav", "audio/wav");
  ]

let content_type ~types path =
  let ext =
    match String.rindex_opt path '.' with
    | None -> ""
    | Some i ->
        String.lowercase_ascii (String.sub path i (String.length path - i))
  in
  match List.assoc_opt ext types with
  | Some t -> t
  | None -> (
      match List.assoc_opt ext content_types with
      | Some t -> t
      | None -> "application/octet-stream")

(* In order of preference. Brotli and zstd are served only where the build
   wrote them: nothing here encodes either. *)
let siblings = [ ("br", ".br"); ("zstd", ".zst"); ("gzip", ".gz") ]

(* The request's weights decide; the order above breaks a tie. *)
let coding req ~available =
  (* Several lines are one list (RFC 9110 §5.3). *)
  match Spindle_http.Field.all (Request.headers req) "accept-encoding" with
  | [] -> None
  | lines -> (
      match Spindle_http.Accept.parse_weighted (String.concat ", " lines) with
      | Error _ -> None
      | Ok w -> (
          match
            Spindle_http.Accept.choose_encoding w
              (List.filter (fun c -> List.mem_assoc c siblings) available
              @ [ "identity" ])
          with
          | Some c when not (String.equal c "identity") -> Some c
          | Some _ | None -> None))

let extension coding = Option.value (List.assoc_opt coding siblings) ~default:""
