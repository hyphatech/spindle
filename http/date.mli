(** An HTTP-date read, as RFC 9110 §5.6.7 has a recipient read one: the
    IMF-fixdate a sender writes ({!Write.date}), and the two obsolete forms a
    recipient must still accept.

    {[
    Date.parse ~now "Sun, 06 Nov 1994 08:49:37 GMT" = Some 784111777000
    Date.parse ~now "Sunday, 06-Nov-94 08:49:37 GMT" = Some 784111777000
    Date.parse ~now "Sun Nov  6 08:49:37 1994" = Some 784111777000
    ]}

    A date is case-sensitive and of a fixed shape, so anything else -- a date
    that does not exist, a time past [23:59:60], a zone but [GMT] -- is [None],
    which is how a recipient treats a date it cannot read: as though the field
    were not sent. *)

val parse : now:int -> string -> int option
(** The instant, in milliseconds since the epoch. [now] is the same, and is what
    the rfc850 form's two-digit year is read against: a date that would be more
    than fifty years ahead of it is the century before, as RFC 9110 says. *)
