(** A connection once a protocol spoken after HTTP has it: a server's after it
    answered [101 Switching Protocols], a client's after its handshake. *)

type t = {
  reader : Eio.Buf_read.t;
      (** may already hold bytes the peer sent after the head, so it is the one
          to read from, never the socket underneath *)
  writer : Eio.Buf_write.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;  (** a monotonic clock *)
  send_timeout_s : float;
      (** how long a write may wait for the peer to take anything *)
  stopping : unit Eio.Promise.t;
      (** resolved when this end begins to stop, while the connection can still
          be written to: a protocol that says goodbye says it then, before what
          is left is cancelled *)
}
