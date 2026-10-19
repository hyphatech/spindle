(** An application's routes as an OCaml module for
    {{:https://melange.re}Melange}: the shapes as types, and a function per
    route that calls it, so a browser written in OCaml calls the server with the
    server's own types and never with a path or a shape typed by hand.

    It is printed from the same walk as {!Openapi.document} and {!Zod.schemas},
    so the three cannot disagree. The module is wiretype's for every component
    -- [Wiretype.Schema.Melange.module_], each a type and the functions that
    read and write it -- with what a route reads or answers that is no component
    given one, named for the route: [get_items_key_answer]. Then [Route], what
    every function calls through, and a function per route, named by its
    operation:

    {[
      let get_items_key ?origin ~key ?lang () = ...
    ]}

    A path parameter is a labelled argument, a query parameter or a header
    optional where the route does not require it, each typed by its component; a
    body is [~body], optional where the route reads an empty one as [{}]; a
    form's file is labelled by its name, a [Js.File.t] -- what a file input
    holds, its name sent with it -- an array where many are read. [origin] is
    prepended to the path, none unless given, so a page calls its own origin. A
    function answers [(answer, Route.error) result Js.Promise.t]: what the route
    answers, read by its description, or what went wrong -- [`Invalid] an input
    that is not what the route reads, every problem listed and nothing sent;
    [`Lost] no answer; [`Refused] the server's refusal; [`Unexpected] an answer
    the route does not say it gives.

    A route that answers a stream of events takes [~on_event], handed each event
    as a variant of the route's, [get_ticks_event], and answers a
    [Route.Stream.t] at once: read over [fetch], so it sends headers and a body
    and reads a refusal as any route does, it ends as [Route.Stream.ended] says
    and stops at [Route.Stream.close], and nothing reconnects. A route that
    answers a WebSocket takes [~on_message], handed each message the server
    sends, typed, and answers a [Route.Socket.t], whose [send] is typed by what
    the client sends, checked before it goes and held until the socket opens;
    [close] and [ended] are a stream's. A socket that reads a header has no
    function, since a browser's WebSocket sends none of the page's choosing, nor
    has a route that answers a response of any kind or reads a body a part at a
    time; a cookie is the browser's to send, and a credential is no parameter.
    The module opens no library: it is Melange over [Js.Json], [Js.Date],
    [Js.Dict] and the browser's [fetch]. *)

val client : ?header:string -> App.t -> (string, string list) result
(** [header] is the comment the module opens with -- what wrote it, and how to
    write it again. [Error] as {!Openapi.document}'s, and where two names in the
    module would be one: two components one name in OCaml, an operation named as
    a component's function, or a route with two inputs under one label. *)
