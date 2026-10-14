type t =
  [ `Continue
  | `Switching_protocols
  | `Early_hints
  | `OK
  | `Created
  | `Accepted
  | `Non_authoritative_information
  | `No_content
  | `Reset_content
  | `Partial_content
  | `Multiple_choices
  | `Moved_permanently
  | `Found
  | `See_other
  | `Not_modified
  | `Use_proxy
  | `Temporary_redirect
  | `Permanent_redirect
  | `Bad_request
  | `Unauthorized
  | `Payment_required
  | `Forbidden
  | `Not_found
  | `Method_not_allowed
  | `Not_acceptable
  | `Proxy_authentication_required
  | `Request_timeout
  | `Conflict
  | `Gone
  | `Length_required
  | `Precondition_failed
  | `Content_too_large
  | `Uri_too_long
  | `Unsupported_media_type
  | `Range_not_satisfiable
  | `Expectation_failed
  | `Misdirected_request
  | `Unprocessable_content
  | `Too_early
  | `Upgrade_required
  | `Precondition_required
  | `Too_many_requests
  | `Request_header_fields_too_large
  | `Unavailable_for_legal_reasons
  | `Internal_server_error
  | `Not_implemented
  | `Bad_gateway
  | `Service_unavailable
  | `Gateway_timeout
  | `Http_version_not_supported
  | `Network_authentication_required
  | `Code of int ]

(* Three matches rather than a table, so a status added without its number
   or phrase is a compile error; a test holds [of_int] to the other two. *)
let to_int : t -> int = function
  | `Continue -> 100
  | `Switching_protocols -> 101
  | `Early_hints -> 103
  | `OK -> 200
  | `Created -> 201
  | `Accepted -> 202
  | `Non_authoritative_information -> 203
  | `No_content -> 204
  | `Reset_content -> 205
  | `Partial_content -> 206
  | `Multiple_choices -> 300
  | `Moved_permanently -> 301
  | `Found -> 302
  | `See_other -> 303
  | `Not_modified -> 304
  | `Use_proxy -> 305
  | `Temporary_redirect -> 307
  | `Permanent_redirect -> 308
  | `Bad_request -> 400
  | `Unauthorized -> 401
  | `Payment_required -> 402
  | `Forbidden -> 403
  | `Not_found -> 404
  | `Method_not_allowed -> 405
  | `Not_acceptable -> 406
  | `Proxy_authentication_required -> 407
  | `Request_timeout -> 408
  | `Conflict -> 409
  | `Gone -> 410
  | `Length_required -> 411
  | `Precondition_failed -> 412
  | `Content_too_large -> 413
  | `Uri_too_long -> 414
  | `Unsupported_media_type -> 415
  | `Range_not_satisfiable -> 416
  | `Expectation_failed -> 417
  | `Misdirected_request -> 421
  | `Unprocessable_content -> 422
  | `Too_early -> 425
  | `Upgrade_required -> 426
  | `Precondition_required -> 428
  | `Too_many_requests -> 429
  | `Request_header_fields_too_large -> 431
  | `Unavailable_for_legal_reasons -> 451
  | `Internal_server_error -> 500
  | `Not_implemented -> 501
  | `Bad_gateway -> 502
  | `Service_unavailable -> 503
  | `Gateway_timeout -> 504
  | `Http_version_not_supported -> 505
  | `Network_authentication_required -> 511
  | `Code n -> n

let of_int : int -> t = function
  | 100 -> `Continue
  | 101 -> `Switching_protocols
  | 103 -> `Early_hints
  | 200 -> `OK
  | 201 -> `Created
  | 202 -> `Accepted
  | 203 -> `Non_authoritative_information
  | 204 -> `No_content
  | 205 -> `Reset_content
  | 206 -> `Partial_content
  | 300 -> `Multiple_choices
  | 301 -> `Moved_permanently
  | 302 -> `Found
  | 303 -> `See_other
  | 304 -> `Not_modified
  | 305 -> `Use_proxy
  | 307 -> `Temporary_redirect
  | 308 -> `Permanent_redirect
  | 400 -> `Bad_request
  | 401 -> `Unauthorized
  | 402 -> `Payment_required
  | 403 -> `Forbidden
  | 404 -> `Not_found
  | 405 -> `Method_not_allowed
  | 406 -> `Not_acceptable
  | 407 -> `Proxy_authentication_required
  | 408 -> `Request_timeout
  | 409 -> `Conflict
  | 410 -> `Gone
  | 411 -> `Length_required
  | 412 -> `Precondition_failed
  | 413 -> `Content_too_large
  | 414 -> `Uri_too_long
  | 415 -> `Unsupported_media_type
  | 416 -> `Range_not_satisfiable
  | 417 -> `Expectation_failed
  | 421 -> `Misdirected_request
  | 422 -> `Unprocessable_content
  | 425 -> `Too_early
  | 426 -> `Upgrade_required
  | 428 -> `Precondition_required
  | 429 -> `Too_many_requests
  | 431 -> `Request_header_fields_too_large
  | 451 -> `Unavailable_for_legal_reasons
  | 500 -> `Internal_server_error
  | 501 -> `Not_implemented
  | 502 -> `Bad_gateway
  | 503 -> `Service_unavailable
  | 504 -> `Gateway_timeout
  | 505 -> `Http_version_not_supported
  | 511 -> `Network_authentication_required
  | n -> `Code n

let equal a b = to_int a = to_int b

(* RFC 9112 §4 allows an empty phrase; a client reads only the number. *)
let reason : t -> string = function
  | `Continue -> "Continue"
  | `Switching_protocols -> "Switching Protocols"
  | `Early_hints -> "Early Hints"
  | `OK -> "OK"
  | `Created -> "Created"
  | `Accepted -> "Accepted"
  | `Non_authoritative_information -> "Non-Authoritative Information"
  | `No_content -> "No Content"
  | `Reset_content -> "Reset Content"
  | `Partial_content -> "Partial Content"
  | `Multiple_choices -> "Multiple Choices"
  | `Moved_permanently -> "Moved Permanently"
  | `Found -> "Found"
  | `See_other -> "See Other"
  | `Not_modified -> "Not Modified"
  | `Use_proxy -> "Use Proxy"
  | `Temporary_redirect -> "Temporary Redirect"
  | `Permanent_redirect -> "Permanent Redirect"
  | `Bad_request -> "Bad Request"
  | `Unauthorized -> "Unauthorized"
  | `Payment_required -> "Payment Required"
  | `Forbidden -> "Forbidden"
  | `Not_found -> "Not Found"
  | `Method_not_allowed -> "Method Not Allowed"
  | `Not_acceptable -> "Not Acceptable"
  | `Proxy_authentication_required -> "Proxy Authentication Required"
  | `Request_timeout -> "Request Timeout"
  | `Conflict -> "Conflict"
  | `Gone -> "Gone"
  | `Length_required -> "Length Required"
  | `Precondition_failed -> "Precondition Failed"
  | `Content_too_large -> "Content Too Large"
  | `Uri_too_long -> "URI Too Long"
  | `Unsupported_media_type -> "Unsupported Media Type"
  | `Range_not_satisfiable -> "Range Not Satisfiable"
  | `Expectation_failed -> "Expectation Failed"
  | `Misdirected_request -> "Misdirected Request"
  | `Unprocessable_content -> "Unprocessable Content"
  | `Too_early -> "Too Early"
  | `Upgrade_required -> "Upgrade Required"
  | `Precondition_required -> "Precondition Required"
  | `Too_many_requests -> "Too Many Requests"
  | `Request_header_fields_too_large -> "Request Header Fields Too Large"
  | `Unavailable_for_legal_reasons -> "Unavailable For Legal Reasons"
  | `Internal_server_error -> "Internal Server Error"
  | `Not_implemented -> "Not Implemented"
  | `Bad_gateway -> "Bad Gateway"
  | `Service_unavailable -> "Service Unavailable"
  | `Gateway_timeout -> "Gateway Timeout"
  | `Http_version_not_supported -> "HTTP Version Not Supported"
  | `Network_authentication_required -> "Network Authentication Required"
  | `Code _ -> ""

let all : t list =
  [
    `Continue;
    `Switching_protocols;
    `Early_hints;
    `OK;
    `Created;
    `Accepted;
    `Non_authoritative_information;
    `No_content;
    `Reset_content;
    `Partial_content;
    `Multiple_choices;
    `Moved_permanently;
    `Found;
    `See_other;
    `Not_modified;
    `Use_proxy;
    `Temporary_redirect;
    `Permanent_redirect;
    `Bad_request;
    `Unauthorized;
    `Payment_required;
    `Forbidden;
    `Not_found;
    `Method_not_allowed;
    `Not_acceptable;
    `Proxy_authentication_required;
    `Request_timeout;
    `Conflict;
    `Gone;
    `Length_required;
    `Precondition_failed;
    `Content_too_large;
    `Uri_too_long;
    `Unsupported_media_type;
    `Range_not_satisfiable;
    `Expectation_failed;
    `Misdirected_request;
    `Unprocessable_content;
    `Too_early;
    `Upgrade_required;
    `Precondition_required;
    `Too_many_requests;
    `Request_header_fields_too_large;
    `Unavailable_for_legal_reasons;
    `Internal_server_error;
    `Not_implemented;
    `Bad_gateway;
    `Service_unavailable;
    `Gateway_timeout;
    `Http_version_not_supported;
    `Network_authentication_required;
  ]
