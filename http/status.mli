(** The statuses a handler may answer with.

    Every status RFC 9110 §15 defines is a constructor, and so are those of RFC
    6585, 7725, 8297 and 8470 -- [`Precondition_required], [`Too_many_requests],
    [`Request_header_fields_too_large], [`Network_authentication_required],
    [`Unavailable_for_legal_reasons], [`Early_hints] and [`Too_early] -- so a
    route reads [~status:`Accepted]; [`Code n] is anything else, WebDAV's among
    them. A status has one spelling: {!of_int} answers the constructor wherever
    there is one, and whatever the framework reports or compares has gone
    through it.

    {b The set is closed at 1.0.} A status registered later stays [`Code n] for
    every 1.x release, so a match on this type keeps its meaning across them:
    one written for [`Code 418] never stops matching. *)

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
