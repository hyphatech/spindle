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
  { min_bytes; level = max 1 (min 9 level); types }

let default = make ()
