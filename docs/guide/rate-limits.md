# Rate limits

```ocaml
let sign_ins = Spindle.Rate.create ~mono_clock ~limit:10 ~per_s:1. ()

(let+ () = Spindle.Rate.limit sign_ins ~key:Spindle.client and+ ... in ...)
```

**A limit is a dependency**, so it is listed where the route is and the
route's document names its `429`: `Rate.limit t ~key` counts the request
against its key -- the client's address, a session, a token, a path
parameter -- and refuses past the limit with `rate_limited`, a code it
declares rather than one of the framework's, with `Retry-After` in whole
seconds. `~limit` calls every `~per_s` seconds, up to `?burst` (`limit`) at
once, by GCRA: one instant per key, the soonest it may call, behind a lock
held for that alone, a key whose instant has passed dropped every thousand
writes. It is the monotonic clock's, which a test gives as `Eio_mock`'s, and
one process's.
