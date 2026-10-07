(** The statuses a handler may answer with.

    Each status HTTP names that a web application commonly answers is a
    constructor, so a route reads [~status:`Accepted]; [`Code n] is anything
    else. A status has one spelling: {!of_int} answers the constructor wherever
    there is one, and whatever the framework reports or compares has gone
    through it. *)

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

val to_int : t -> int

val of_int : int -> t
(** The named constructor for [n], or [`Code n] when there is none: [of_int 409]
    is [`Conflict], never [`Code 409]. *)

val equal : t -> t -> bool
(** By number, so [`Code 409] and [`Conflict] are one status. *)

val reason : t -> string
(** The phrase a status line carries -- ["Not Found"] -- and empty for a [`Code]
    with no name, which RFC 9112 allows. *)

val all : t list
(** Every named status, in numeric order. *)
