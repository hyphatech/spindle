(** An HTTP-date read, as RFC 9110 §5.6.7 has a recipient read one: the
    IMF-fixdate a sender writes ({!to_string}), and the two obsolete forms a
    recipient must still accept.

    {[
    (* each [Some] of the instant 1994-11-06T08:49:37Z *)
    let imf = Date.parse ~now "Sun, 06 Nov 1994 08:49:37 GMT"
    let rfc850 = Date.parse ~now "Sunday, 06-Nov-94 08:49:37 GMT"
    let asctime = Date.parse ~now "Sun Nov  6 08:49:37 1994"
    ]}

    A date is case-sensitive and of a fixed shape, so anything else -- a date
    that does not exist, a time past [23:59:60], a zone but [GMT] -- is [None],
    which is how a recipient treats a date it cannot read: as though the field
    were not sent. *)

val parse : now:Ptime.t -> string -> Ptime.t option
(** The instant. [now] is what the rfc850 form's two-digit year is read against:
    a date that would be more than fifty years ahead of it is the century
    before, as RFC 9110 says. A second of [60], a leap second, is the next
    minute's first. *)

val to_string : Ptime.t -> string
(** An instant as RFC 9110 §5.6.7's IMF-fixdate --
    [Sun, 06 Nov 1994 08:49:37 GMT] -- which is the one form of date a sender
    may write, its fraction of a second dropped: a [Last-Modified], an
    [Expires]. *)
