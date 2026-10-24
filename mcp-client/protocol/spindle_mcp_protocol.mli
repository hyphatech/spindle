(** The Model Context Protocol's messages, as both ends read and write them:
    JSON-RPC 2.0 as MCP 2026-07-28 uses it, and the protocol's version. It does
    no I/O, so the server and the client read one message one way. *)

val version : string
(** ["2026-07-28"]: the one version spoken, by both ends. *)

(** A request's id: MCP's are a string or an integer, never [null]. *)
type id = Int of int | String of string

val id_to_value : id -> Wiretype.Value.t

(** A message a client sends. *)
type message =
  | Request of { id : id; meth : string; params : Wiretype.Value.t option }
  | Notification of { meth : string; params : Wiretype.Value.t option }

(** Why a body is no message a client may send. *)
type error =
  | Parse_error  (** not JSON *)
  | Invalid_request of string
      (** JSON, but no request or notification: a batch, which MCP has none of,
          a [null] id, a response, or no ["jsonrpc": "2.0"] and method; in words
      *)

val read : string -> (message, error) result

val member : string -> Wiretype.Value.t option -> Wiretype.Value.t option
(** [member name params]: that member of an object, where there is one. *)

(** {1 Answers} *)

val result : id -> (string * Wiretype.Value.t) list -> string
(** A result response: the members given, in order. *)

(** The codes MCP answers with: JSON-RPC's [-32700], [-32600], [-32601] and
    [-32602], and MCP's own [-32020], [-32021] and [-32022]. *)
module Code : sig
  val parse_error : int
  val invalid_request : int
  val method_not_found : int
  val invalid_params : int
  val header_mismatch : int
  val missing_capability : int
  val unsupported_version : int
end

val error : ?id:id -> ?data:Wiretype.Value.t -> int -> string -> string
(** An error response: the code, the message, and [data] where given. [id] is
    the request's, and absent where it could not be read. *)
