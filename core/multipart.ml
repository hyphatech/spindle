module M = Spindle_http.Multipart

type t = Body.error M.t

type part = M.part = {
  name : string;
  filename : string option;
  content_type : Spindle_http.Media_type.t;
  headers : (string * string) list;
}

type error = Malformed of string | Head_too_large | Body of Body.error

let of_http_error = function
  | M.Malformed m -> Malformed m
  | M.Head_too_large -> Head_too_large
  | M.Source e -> Body e

let next t = Result.map_error of_http_error (M.next t)
let read t = Result.map_error of_http_error (M.read t)

let refusal = function
  | Malformed detail ->
      Refusal.make ~detail
        ~problems:
          [
            {
              Refusal.at = "body";
              code = "malformed";
              message = "This is not a multipart form.";
            };
          ]
        Refusal.Code.invalid "Some of that request is not what it should be."
  | Head_too_large -> Refusal.too_large
  | Body e -> Body.refusal e
