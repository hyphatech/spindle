include Compress_repr

let text_types =
  [
    "text/*";
    "application/json";
    "application/*+json";
    "application/xml";
    "application/*+xml";
    "application/javascript";
    "image/svg+xml";
  ]

let make ?(min_bytes = 1024) ?(level = 6) ?(types = text_types) () =
  if level < 1 || level > 9 then
    invalid_arg
      (Printf.sprintf "Spindle.Compress.make: ~level:%d, not 1 to 9" level);
  if min_bytes < 0 then
    invalid_arg
      (Printf.sprintf "Spindle.Compress.make: ~min_bytes:%d, below zero"
         min_bytes);
  { min_bytes; level; types }

let default = make ()
