(* A GET of a representation: RFC 9110 §13.2.2's order of preconditions,
   then §14's range. One account for every file the framework serves. *)

module Etag = Spindle_http.Etag
module Date = Spindle_http.Date
module Range = Spindle_http.Range

type validators = {
  tag : Etag.t;
  modified_ms : int option;  (** where the representation has a date *)
}

type answer =
  | Precondition_failed
  | Not_modified
  | Whole
  | Part of { first : int; last : int }
  | Unsatisfiable

(* Several lines are one list (RFC 9110 §5.3). *)
let joined_field req name =
  match Spindle_http.Field.all (Request.headers req) name with
  | [] -> None
  | values -> Some (String.concat ", " values)

(* An HTTP-date is to the second. *)
let to_seconds ms = if ms >= 0 then ms / 1000 else ((ms + 1) / 1000) - 1

let date_field req name =
  Option.bind (joined_field req name) (Date.parse ~now:(Request.now req))

(* §13.1.1, §13.1.4. An unreadable If-Match matches nothing. *)
let if_match_passes req v =
  match joined_field req "if-match" with
  | None -> (
      match (date_field req "if-unmodified-since", v.modified_ms) with
      | Some since, Some m -> to_seconds m <= to_seconds since
      | (Some _ | None), (Some _ | None) -> true)
  | Some value -> (
      match Etag.condition value with
      | Ok Etag.Any -> true
      | Ok (Etag.Tags tags) -> List.exists (Etag.strong_equal v.tag) tags
      | Error _ -> false)

(* §13.1.2, §13.1.3: the client already holds this representation. A date in
   the future is ignored. *)
let client_has_current req v =
  match joined_field req "if-none-match" with
  | Some value -> (
      match Etag.condition value with
      | Ok Etag.Any -> true
      | Ok (Etag.Tags tags) -> List.exists (Etag.weak_equal v.tag) tags
      | Error _ -> false)
  | None -> (
      match (date_field req "if-modified-since", v.modified_ms) with
      | Some since, Some m when since <= Request.now req ->
          to_seconds m <= to_seconds since
      | (Some _ | None), (Some _ | None) -> false)

(* §13.1.5: by a strong tag or the exact date; a weak tag never matches. A
   tag is told from a date by its quote, never its first letter: Wednesday
   begins with W. *)
let if_range_passes req v =
  let looks_like_tag value =
    String.starts_with ~prefix:"\"" value
    || String.starts_with ~prefix:"W/\"" value
  in
  match joined_field req "if-range" with
  | None -> true
  | Some value when looks_like_tag value -> (
      match Etag.parse value with
      | Ok tag -> Etag.strong_equal v.tag tag
      | Error _ -> false)
  | Some value -> (
      match (Date.parse ~now:(Request.now req) value, v.modified_ms) with
      | Some d, Some m -> to_seconds m = to_seconds d
      | (Some _ | None), (Some _ | None) -> false)

(* §14.2: only a GET, and only one range, in part; an empty representation
   has no part to describe. *)
let range_answer req v ~length =
  match (Request.meth req, joined_field req "range") with
  | `GET, Some value when length > 0 && if_range_passes req v -> (
      match Range.parse value with
      | Ok (Range.Bytes [ spec ]) -> (
          match Range.satisfy ~length spec with
          | Some (first, last) -> Part { first; last }
          | None -> Unsatisfiable)
      | Ok (Range.Bytes _ | Range.Other _) | Error _ -> Whole)
  | _, (Some _ | None) -> Whole

let decide req v ~length =
  if not (if_match_passes req v) then Precondition_failed
  else if client_has_current req v then Not_modified
  else range_answer req v ~length

(* The framework's own tags are digests in hex, which are always written; one
   that could not be is left out rather than written wrong. *)
let etag_header v =
  match Etag.to_string v.tag with Ok tag -> [ ("etag", tag) ] | Error _ -> []

let representation_headers v ~headers =
  (("accept-ranges", "bytes") :: etag_header v)
  @ Option.to_list
      (Option.map
         (fun m -> ("last-modified", Spindle_http.Write.date m))
         v.modified_ms)
  @ headers

(* A 304 repeats the tag alone: RFC 9110 §15.4.5 repeats a date only where
   there is no tag. *)
let bodiless_response v ~headers ~length = function
  | Precondition_failed ->
      Some (Response.empty ~status:`Precondition_failed ~headers ())
  | Not_modified ->
      Some
        (Response.empty ~status:`Not_modified
           ~headers:(etag_header v @ headers)
           ())
  | Unsatisfiable ->
      Some
        (Response.empty ~status:`Range_not_satisfiable
           ~headers:
             (("content-range", Range.content_range_unsatisfied ~length)
             :: ("accept-ranges", "bytes") :: headers)
           ())
  | Whole | Part _ -> None

(* Listed as headers, so a route that answers a file declares them. *)
let inputs =
  let header name =
    Dep.Header
      {
        name;
        required = false;
        many = true;
        shape = Codec.shape Codec.string;
        kind = None;
      }
  in
  Dep.of_request
    ~needs:
      (List.map header
         [
           "if-match";
           "if-unmodified-since";
           "if-none-match";
           "if-modified-since";
           "range";
           "if-range";
         ])
    (fun req -> Ok req)
