(* A resource server: notes behind OAuth 2.0 bearer tokens, which an
   authorization server elsewhere issues. Each token is checked against the
   issuer's keys, fetched from its metadata; a client that has none is told
   where to read about getting one.

     curl -i localhost:8080/notes
     curl localhost:8080/.well-known/oauth-protected-resource *)

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env ->
  Spindle_client.run env @@ fun client ->
  let keys =
    Spindle_client.Oauth.keys client ~issuer:"https://id.example.com"
  in
  Spindle.serve env
    ~resources:
      [ Spindle.Dep.resource (Spindle.Bearer.keys Notes_auth.auth) keys ]
    (Notes_routes.routes
    @ [ Spindle.Bearer.metadata Notes_auth.auth Notes_routes.routes ]
    @ Spindle.Openapi.routes ~title:"Notes" Notes_routes.routes)
