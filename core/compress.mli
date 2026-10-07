(** Answers compressed with gzip, streams included: one policy for the app
    ({!App.make}'s [compress]), off unless given, because it is CPU the process
    pays and the proxy in front often compresses already.

    {[
    Spindle.serve env ~compress:Spindle.Compress.default routes
    ]}

    {b What is compressed}: a buffered answer of a listed type and at least
    [min_bytes], or a stream of one whose length is not known, to a client whose
    [Accept-Encoding] takes gzip, where the answer names no [Content-Encoding]
    of its own, says no [Cache-Control: no-transform], is no part of a range,
    and is on a route that did not say {!never}. A [HEAD] gets the length its
    [GET] would. Every answer of a listed type says [Vary: Accept-Encoding],
    compressed or not, and an entity tag on a compressed one carries the coding
    inside its quotes, so the two representations are never taken for one.

    {b A stream is compressed as it goes}: every [send] reaches the client as a
    sync flush, so what it sent can be decoded when it arrives and an event is
    not held back. A file of a known length is not compressed as it is read; its
    precompressed sibling is served instead ({!Static}, {!Files}).

    {b A route that answers a secret beside what a request sent} -- where the
    length of a compressed answer lets an observer guess the secret -- says so:
    [~meta:Meta.(empty |> add Compress.never ())]. *)

type t = Compress_repr.t

val make : ?min_bytes:int -> ?level:int -> ?types:string list -> unit -> t
(** [min_bytes] (1024) is the least an answer is worth compressing at; [level]
    (6) is deflate's, 1 to 9; [types] are what is compressed, each
    [type/subtype], [type/*] or [type/*+suffix]: text, JSON, XML, JavaScript,
    SVG and event streams unless given. *)

val default : t
(** [make ()]: what an application that compresses usually wants. *)

val never : unit Meta.key
(** A route whose answers are never compressed. *)
