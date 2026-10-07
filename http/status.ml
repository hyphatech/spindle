type t =
  [ `Switching_protocols
  | `OK
  | `Created
  | `Accepted
  | `No_content
  | `Partial_content
  | `Moved_permanently
  | `Found
  | `See_other
  | `Not_modified
  | `Temporary_redirect
  | `Permanent_redirect
  | `Bad_request
  | `Unauthorized
  | `Forbidden
  | `Not_found
  | `Method_not_allowed
  | `Request_timeout
  | `Conflict
  | `Gone
  | `Precondition_failed
  | `Content_too_large
  | `Uri_too_long
  | `Unsupported_media_type
  | `Range_not_satisfiable
  | `Unprocessable_content
  | `Upgrade_required
  | `Too_many_requests
  | `Request_header_fields_too_large
  | `Internal_server_error
  | `Not_implemented
  | `Bad_gateway
  | `Service_unavailable
  | `Gateway_timeout
  | `Http_version_not_supported
  | `Code of int ]

(* Three matches rather than a table, so a status added without its number
   or phrase is a compile error; a test holds [of_int] to the other two. *)
let to_int : t -> int = function
  | `Switching_protocols -> 101
  | `OK -> 200
  | `Created -> 201
  | `Accepted -> 202
  | `No_content -> 204
  | `Partial_content -> 206
  | `Moved_permanently -> 301
  | `Found -> 302
  | `See_other -> 303
  | `Not_modified -> 304
  | `Temporary_redirect -> 307
  | `Permanent_redirect -> 308
  | `Bad_request -> 400
  | `Unauthorized -> 401
  | `Forbidden -> 403
  | `Not_found -> 404
  | `Method_not_allowed -> 405
  | `Request_timeout -> 408
  | `Conflict -> 409
  | `Gone -> 410
  | `Precondition_failed -> 412
  | `Content_too_large -> 413
  | `Uri_too_long -> 414
  | `Unsupported_media_type -> 415
  | `Range_not_satisfiable -> 416
  | `Unprocessable_content -> 422
  | `Upgrade_required -> 426
  | `Too_many_requests -> 429
  | `Request_header_fields_too_large -> 431
  | `Internal_server_error -> 500
  | `Not_implemented -> 501
  | `Bad_gateway -> 502
  | `Service_unavailable -> 503
  | `Gateway_timeout -> 504
  | `Http_version_not_supported -> 505
  | `Code n -> n

let of_int : int -> t = function
  | 101 -> `Switching_protocols
  | 200 -> `OK
  | 201 -> `Created
  | 202 -> `Accepted
  | 204 -> `No_content
  | 206 -> `Partial_content
  | 301 -> `Moved_permanently
  | 302 -> `Found
  | 303 -> `See_other
  | 304 -> `Not_modified
  | 307 -> `Temporary_redirect
  | 308 -> `Permanent_redirect
  | 400 -> `Bad_request
  | 401 -> `Unauthorized
  | 403 -> `Forbidden
  | 404 -> `Not_found
  | 405 -> `Method_not_allowed
  | 408 -> `Request_timeout
  | 409 -> `Conflict
  | 410 -> `Gone
  | 412 -> `Precondition_failed
  | 413 -> `Content_too_large
  | 414 -> `Uri_too_long
  | 415 -> `Unsupported_media_type
  | 416 -> `Range_not_satisfiable
  | 422 -> `Unprocessable_content
  | 426 -> `Upgrade_required
  | 429 -> `Too_many_requests
  | 431 -> `Request_header_fields_too_large
  | 500 -> `Internal_server_error
  | 501 -> `Not_implemented
  | 502 -> `Bad_gateway
  | 503 -> `Service_unavailable
  | 504 -> `Gateway_timeout
  | 505 -> `Http_version_not_supported
  | n -> `Code n

let equal a b = to_int a = to_int b

(* RFC 9112 §4 allows an empty phrase; a client reads only the number. *)
let reason : t -> string = function
  | `Switching_protocols -> "Switching Protocols"
  | `OK -> "OK"
  | `Created -> "Created"
  | `Accepted -> "Accepted"
  | `No_content -> "No Content"
  | `Partial_content -> "Partial Content"
  | `Moved_permanently -> "Moved Permanently"
  | `Found -> "Found"
  | `See_other -> "See Other"
  | `Not_modified -> "Not Modified"
  | `Temporary_redirect -> "Temporary Redirect"
  | `Permanent_redirect -> "Permanent Redirect"
  | `Bad_request -> "Bad Request"
  | `Unauthorized -> "Unauthorized"
  | `Forbidden -> "Forbidden"
  | `Not_found -> "Not Found"
  | `Method_not_allowed -> "Method Not Allowed"
  | `Request_timeout -> "Request Timeout"
  | `Conflict -> "Conflict"
  | `Gone -> "Gone"
  | `Precondition_failed -> "Precondition Failed"
  | `Content_too_large -> "Content Too Large"
  | `Uri_too_long -> "URI Too Long"
  | `Unsupported_media_type -> "Unsupported Media Type"
  | `Range_not_satisfiable -> "Range Not Satisfiable"
  | `Unprocessable_content -> "Unprocessable Content"
  | `Upgrade_required -> "Upgrade Required"
  | `Too_many_requests -> "Too Many Requests"
  | `Request_header_fields_too_large -> "Request Header Fields Too Large"
  | `Internal_server_error -> "Internal Server Error"
  | `Not_implemented -> "Not Implemented"
  | `Bad_gateway -> "Bad Gateway"
  | `Service_unavailable -> "Service Unavailable"
  | `Gateway_timeout -> "Gateway Timeout"
  | `Http_version_not_supported -> "HTTP Version Not Supported"
  | `Code _ -> ""

let all : t list =
  [
    `Switching_protocols;
    `OK;
    `Created;
    `Accepted;
    `No_content;
    `Partial_content;
    `Moved_permanently;
    `Found;
    `See_other;
    `Not_modified;
    `Temporary_redirect;
    `Permanent_redirect;
    `Bad_request;
    `Unauthorized;
    `Forbidden;
    `Not_found;
    `Method_not_allowed;
    `Request_timeout;
    `Conflict;
    `Gone;
    `Precondition_failed;
    `Content_too_large;
    `Uri_too_long;
    `Unsupported_media_type;
    `Range_not_satisfiable;
    `Unprocessable_content;
    `Upgrade_required;
    `Too_many_requests;
    `Request_header_fields_too_large;
    `Internal_server_error;
    `Not_implemented;
    `Bad_gateway;
    `Service_unavailable;
    `Gateway_timeout;
    `Http_version_not_supported;
  ]
