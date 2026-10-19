module L = (val Logs.src_log Log.http : Logs.LOG)

(* A function, so a route that sets nothing never mentions it. *)
let setter f : _ Dep.t =
  Dep_repr.make (fun (c : Dep_repr.context) ->
      Now
        (Ok
           (fun v ->
             let o = c.outgoing in
             if o.sent then
               L.warn (fun m ->
                   m
                     "%s set a cookie or a header after its answer had gone, \
                      which changed nothing"
                     o.pattern)
             else f o v)))

let set_cookie =
  setter (fun (o : Dep_repr.outgoing) c -> o.cookies <- o.cookies @ [ c ])

let add_header =
  setter (fun (o : Dep_repr.outgoing) h -> o.headers <- o.headers @ [ h ])
