(* TLS for a test: a certificate of the suite's own, and a front that speaks
   TLS to a client and plain HTTP to a server, as a proxy before one does. *)

(* What a certificate names: the loopback address the tests call and
   [localhost], or the name alone -- which a call to the address must then
   refuse. *)
type certified = Name_and_address | Name_only

(* The server's half, and an authenticator that trusts its key and nothing
   else -- and checks the name or address the client says it is calling, as
   a real one does. Made once for each, since a key takes a while. *)
let certificate =
  let make certified =
    Mirage_crypto_rng_unix.use_default ();
    let key = X509.Private_key.generate `P256 in
    let name =
      X509.Distinguished_name.
        [
          Relative_distinguished_name.singleton (CN (Common_name.v "localhost"));
        ]
    in
    let names = X509.General_name.singleton DNS [ "localhost" ] in
    let names =
      match certified with
      | Name_and_address ->
          X509.General_name.add IP
            [ Ipaddr.V4.to_octets Ipaddr.V4.localhost ]
            names
      | Name_only -> names
    in
    let extensions = X509.Extension.singleton Subject_alt_name (false, names) in
    let certificate =
      match X509.Signing_request.create name key with
      | Error (`Msg m) -> Alcotest.fail m
      | Ok csr -> (
          match
            X509.Signing_request.sign csr ~valid_from:Ptime.epoch
              ~valid_until:
                (Option.value (Ptime.of_float_s 4e9) ~default:Ptime.max)
              ~extensions key name
          with
          | Ok c -> c
          | Error e -> Alcotest.failf "%a" X509.Validation.pp_signature_error e)
    in
    let config =
      match
        Tls.Config.server ~certificates:(`Single ([ certificate ], key)) ()
      with
      | Ok c -> c
      | Error (`Msg m) -> Alcotest.fail m
    in
    let fingerprint =
      X509.Public_key.fingerprint ~hash:`SHA256 (X509.Private_key.public key)
    in
    let authenticator : X509.Authenticator.t =
     fun ?ip ~host chain ->
      X509.Validation.trust_key_fingerprint ?ip ~host
        ~time:(fun () -> Ptime.of_float_s (Unix.gettimeofday ()))
        ~hash:`SHA256 ~fingerprint chain
    in
    (config, authenticator)
  in
  let both = lazy (make Name_and_address) and name = lazy (make Name_only) in
  function Name_and_address -> Lazy.force both | Name_only -> Lazy.force name

(* A front for the server on [port], which a client calls as [localhost]:
   its port, and the authenticator that trusts it. *)
let listen ~sw ~net ~port =
  let config, authenticator = certificate Name_only in
  let socket =
    Eio.Net.listen net ~sw ~backlog:4 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let front =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, p) -> p
    | _ -> Alcotest.fail "expected a TCP socket"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec accept () =
        Eio.Net.accept_fork socket ~sw
          ~on_error:(fun _ -> ())
          (fun flow _ ->
            let tls = Tls_eio.server_of_flow config flow in
            Eio.Switch.run @@ fun sw ->
            let back =
              Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
            in
            Eio.Fiber.first
              (fun () -> Eio.Flow.copy tls back)
              (fun () -> Eio.Flow.copy back tls));
        accept ()
      in
      accept ());
  (front, authenticator)
