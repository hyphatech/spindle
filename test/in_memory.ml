(* A server under test on virtual time, and connections to it in memory.
   Eio's mock backend keeps the clock and moves it only once every fiber is
   waiting, straight to the next one due: a test says how long its client
   pauses, and what the server does meanwhile is the same on every machine
   at any load. Each way of a connection holds a socket buffer's worth, so a
   client that stops reading holds the server's write back as a kernel
   would. One domain: a further domain the server asks for is a fiber of
   this one. *)

type Eio.Exn.Backend.t += Peer_closed

(* One direction of a connection: what one end wrote and the other has not
   read yet, at most [capacity] bytes of it. *)
module Pipe = struct
  type t = {
    pending : Buffer.t;
    changed : Eio.Condition.t;
    mutable writing_ended : bool;  (** no more is coming: read to the end *)
    mutable reading_ended : bool;  (** nobody will read: a write is a reset *)
    piecewise : bool;  (** a write returns once it has been read *)
  }

  let capacity = 64 * 1024

  let create ~piecewise =
    {
      pending = Buffer.create capacity;
      changed = Eio.Condition.create ();
      writing_ended = false;
      reading_ended = false;
      piecewise;
    }

  let rec await_read t =
    if Buffer.length t.pending > 0 && not t.reading_ended then begin
      Eio.Condition.await_no_mutex t.changed;
      await_read t
    end

  let rec read t buf =
    let have = Buffer.length t.pending in
    if have > 0 then begin
      let n = min have (Cstruct.length buf) in
      Cstruct.blit_from_string (Buffer.sub t.pending 0 n) 0 buf 0 n;
      let rest = Buffer.sub t.pending n (have - n) in
      Buffer.clear t.pending;
      Buffer.add_string t.pending rest;
      Eio.Condition.broadcast t.changed;
      n
    end
    else if t.writing_ended || t.reading_ended then raise End_of_file
    else begin
      Eio.Condition.await_no_mutex t.changed;
      read t buf
    end

  let rec write t bufs =
    if t.reading_ended || t.writing_ended then
      raise (Eio.Net.err (Connection_reset Peer_closed))
    else
      let room = capacity - Buffer.length t.pending in
      if room > 0 then begin
        let n = min room (Cstruct.lenv bufs) in
        Buffer.add_string t.pending
          (Cstruct.to_string ~len:n (Cstruct.concat bufs));
        Eio.Condition.broadcast t.changed;
        if t.piecewise then await_read t;
        n
      end
      else begin
        Eio.Condition.await_no_mutex t.changed;
        write t bufs
      end

  let end_writing t =
    t.writing_ended <- true;
    Eio.Condition.broadcast t.changed

  let end_reading t =
    t.reading_ended <- true;
    Eio.Condition.broadcast t.changed
end

(* One end of a connection: it reads what the other end wrote. *)
module Socket = struct
  type t = { incoming : Pipe.t; outgoing : Pipe.t }
  type tag = [ `Generic ]

  let read_methods = []
  let single_read t buf = Pipe.read t.incoming buf
  let single_write t bufs = Pipe.write t.outgoing bufs
  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src

  let shutdown t = function
    | `Send -> Pipe.end_writing t.outgoing
    | `Receive -> Pipe.end_reading t.incoming
    | `All ->
        Pipe.end_writing t.outgoing;
        Pipe.end_reading t.incoming

  let setsockopt _ _ _ = ()
  let getsockopt _ _ = raise (Eio.Net.err Invalid_option)

  let close t =
    Pipe.end_writing t.outgoing;
    Pipe.end_reading t.incoming
end

let socket s =
  (Eio.Resource.T (s, Eio.Net.Pi.stream_socket (module Socket))
    : [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t)

(* What the server accepts: the connections [connect] made, in order. *)
module Listening = struct
  type t = Socket.t Eio.Stream.t
  type tag = [ `Generic ]

  let setsockopt _ _ _ = ()
  let getsockopt _ _ = raise (Eio.Net.err Invalid_option)

  let accept t ~sw:_ =
    (socket (Eio.Stream.take t), `Tcp (Eio.Net.Ipaddr.V4.loopback, 1))

  let close _ = ()
  let listening_addr _ = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80)
end

(* A socket for [Spindle.Server.serve_on] to listen on, and the client's
   way to connect to it, closed with the switch it is given. On a
   [piecewise] one, a client's every write is read before the next is sent,
   so the server reads the pieces a test chose, as no kernel promises. *)
let listen ?(piecewise = false) () =
  let waiting = Eio.Stream.create max_int in
  let listening =
    (Eio.Resource.T (waiting, Eio.Net.Pi.listening_socket (module Listening))
      : [ `Generic ] Eio.Net.listening_socket_ty Eio.Resource.t)
  in
  let connect ~sw =
    let there = Pipe.create ~piecewise
    and back = Pipe.create ~piecewise:false in
    let ours = { Socket.incoming = back; outgoing = there } in
    Eio.Stream.add waiting { Socket.incoming = there; outgoing = back };
    Eio.Switch.on_release sw (fun () -> Socket.close ours);
    socket ours
  in
  (listening, connect)

(* A flow's reads, each of which must end at the instant it began: on
   virtual time a server that waits where it should not would otherwise be
   answered by its own idle limit, a minute on, and read as if it had closed
   or answered at once. *)
module At_once = struct
  type t = {
    flow : Eio.Flow.source_ty Eio.Resource.t;
    clock : Eio.Time.Mono.ty Eio.Resource.t;
  }

  let read_methods = []

  let single_read t buf =
    let began = Eio.Time.Mono.now t.clock in
    let ended () =
      let now = Eio.Time.Mono.now t.clock in
      if not (Mtime.equal began now) then
        Alcotest.failf "the server kept the client waiting %a" Mtime.Span.pp
          (Mtime.span began now)
    in
    match Eio.Flow.single_read t.flow buf with
    | n ->
        ended ();
        n
    | exception End_of_file ->
        ended ();
        raise End_of_file
end

let at_once ~clock flow =
  let t : At_once.t =
    {
      flow :> Eio.Flow.source_ty Eio.Resource.t;
      clock :> Eio.Time.Mono.ty Eio.Resource.t;
    }
  in
  Eio.Resource.T (t, Eio.Flow.Pi.source (module At_once))

(* Past an hour of virtual time a test is waiting for something that will
   not come: a server's sweep ticks for ever, so the backend never finds
   every fiber idle to report the deadlock itself. *)
let hour = 3600.

let run f =
  Eio_mock.Backend.run_full @@ fun mock ->
  let env =
    object
      method clock = mock#clock
      method mono_clock = mock#mono_clock
      method domain_mgr = Eio_mock.Domain_manager.create ()
    end
  in
  Eio.Fiber.first
    (fun () -> f env)
    (fun () ->
      Eio.Time.Mono.sleep mock#mono_clock hour;
      Alcotest.fail "an hour of virtual time went by: the test waits for ever")
