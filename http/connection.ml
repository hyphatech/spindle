type t = {
  reader : Eio.Buf_read.t;
  writer : Eio.Buf_write.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  send_timeout_s : float;
  stopping : unit Eio.Promise.t;
}
