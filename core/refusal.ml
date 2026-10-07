module Status = Spindle_http.Status
module Meth = Spindle_http.Meth

module Code = struct
  type t = {
    name : string;
    status : Status.t;
    challenge : string option;
    doc : string;
  }

  (* Normalised, so [`Code 409] and [`Conflict] are one status. *)
  let make ?challenge name ~status ~doc =
    { name; status = Status.of_int (Status.to_int status); challenge; doc }

  let name c = c.name
  let status c = c.status
  let challenge c = c.challenge
  let doc c = c.doc
  let equal a b = String.equal a.name b.name
  let not_found = make "not_found" ~status:`Not_found ~doc:"Nothing is here."

  let method_not_allowed =
    make "method_not_allowed" ~status:`Method_not_allowed
      ~doc:"The path is answered, but not by this method; Allow lists those."

  (* A body that never arrived whole; one of the wrong shape is [invalid]. *)
  let unreadable =
    make "unreadable" ~status:`Bad_request
      ~doc:
        "The body could not be read as sent: cut short, malformed, or too slow \
         to arrive."

  let invalid =
    make "invalid" ~status:`Bad_request
      ~doc:"Inputs are not what the route reads; each problem says where."

  let too_large =
    make "too_large" ~status:`Content_too_large
      ~doc:"The body is longer than the server takes."

  let busy =
    make "busy" ~status:`Service_unavailable
      ~doc:"Something the request needed did not come free in time; try again."

  let unsupported_media_type =
    make "unsupported_media_type" ~status:`Unsupported_media_type
      ~doc:"The body is sent as something the route does not read."

  let cross_origin =
    make "cross_origin" ~status:`Forbidden
      ~doc:"A browser sent a request that changes something from another site."

  let not_implemented =
    make "not_implemented" ~status:`Not_implemented
      ~doc:"The method is not one this server implements."

  let upgrade_required =
    make "upgrade_required" ~status:`Upgrade_required
      ~doc:
        "The address is a WebSocket, answered only to a request that opens \
         one; Upgrade says which."

  let internal =
    make "internal" ~status:`Internal_server_error ~doc:"The server's fault."

  let rate_limited =
    make "rate_limited" ~status:`Too_many_requests
      ~doc:
        "The caller asked more often than the route allows; Retry-After says \
         when to ask again."

  let framework =
    [
      not_found;
      method_not_allowed;
      unreadable;
      invalid;
      too_large;
      busy;
      cross_origin;
      not_implemented;
      upgrade_required;
      internal;
    ]
end

type problem = { at : string; code : string; message : string }

type t = {
  code : Code.t;
  message : string;
  detail : string option;
  raised : (exn * Printexc.raw_backtrace) option;
  headers : (string * string) list;
  problems : problem list;
}

(* The code carries the challenge, so no 401 can forget it (RFC 9110
   §15.5.2). *)
let make ?detail ?(headers = []) ?(problems = []) code message =
  let challenge =
    match Code.challenge code with
    | Some c -> [ ("www-authenticate", c) ]
    | None -> []
  in
  {
    code;
    message;
    detail;
    raised = None;
    headers = challenge @ headers;
    problems;
  }

let status r = Code.status r.code
let not_found = make Code.not_found "There is nothing here."

let method_not_allowed ~allow =
  make Code.method_not_allowed
    ~headers:[ ("allow", String.concat ", " (List.map Meth.to_string allow)) ]
    "That is not something you can do here."

let unreadable ~detail =
  make ~detail Code.unreadable "That request could not be read."

let invalid problems =
  make ~problems Code.invalid "Some of that request is not what it should be."

let too_large = make Code.too_large "That request is too large."

let internal ~detail =
  make ~detail Code.internal
    "Something went wrong at our end. Please try again."

let raised ex bt =
  { (internal ~detail:(Printexc.to_string ex)) with raised = Some (ex, bt) }

let rate_limited ~retry_after () =
  make Code.rate_limited
    ~headers:[ ("retry-after", string_of_int (max 1 retry_after)) ]
    "That was asked too often. Please try again in a moment."

let busy ?(retry_after = 1) ?detail () =
  make ?detail Code.busy
    ~headers:[ ("retry-after", string_of_int retry_after) ]
    "The server is busy. Please try again in a moment."

let unsupported_media_type =
  make Code.unsupported_media_type
    "That request's body is not in a form this can read."

let not_implemented =
  make Code.not_implemented "That is not something this server does."

let cross_origin =
  make Code.cross_origin
    "That request came from another site, so it was not carried out."
