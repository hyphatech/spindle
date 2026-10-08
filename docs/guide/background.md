# Background jobs

Some work should not hold up the answer: sending an email, or checking on
something later. `Spindle.Background` runs work now, on its own fiber;
`Spindle.Alarm` runs it after a delay.

```ocaml
Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let background = Spindle.Background.create ~sw in
let alarms =
  Spindle.Alarm.create ~background ~mono_clock:(Eio.Stdenv.mono_clock env) ()
in
let sign_up =
  Spindle.post
    Spindle.Path.(s "sign-up")
    (Spindle.Returns.empty ~status:`Created ())
    (let+ email = Spindle.body in
     Spindle.Background.fork background ~what:"welcome email" (fun () ->
         send_welcome_email email);
     Spindle.Alarm.set alarms ~key:("reminder:" ^ email) ~in_ms:86_400_000
       ~what:"reminder" (fun () -> send_reminder email);
     Ok ())
in
...
```

## Running a job now

- Create one with `Background.create ~sw` at startup, then call
  `Background.fork t ~what f` from anywhere. It returns at once.
- If `f` raises, the exception is **logged, never raised**, as an `error` on
  `spindle.background` naming `what` and the request that forked it. A bug in
  a job never takes the server down.
- The fiber is a daemon: it does not keep the process from shutting down.
- It runs on the domain that forked it.

## Running a job later

- `Alarm.create ~background ~mono_clock ()`, then
  `Alarm.set t ~key ~in_ms ~what f`: run `f` in `in_ms` milliseconds (plus
  `?slack_ms`, 50 by default).
- One wake-up per key: setting a key again replaces the earlier one, and
  `Alarm.cancel t ~key` drops it.
- Timing uses the monotonic clock, so changing the system time moves nothing.
- An alarm decides *when* to look, not what is true then: when it fires, read
  the time and what is due afresh. Alarms live in memory, so a restart
  forgets them.
