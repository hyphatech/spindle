(** An application's routes as a TypeScript module of {{:https://zod.dev}zod}
    schemas, for a client to parse what the server sends with the same shapes
    the server describes.

    It is printed from the same walk as {!Openapi.document}, so the two cannot
    disagree. Each component is [export const <Name>Schema] with its type
    [z.infer]red beside it, each after those it refers to, the refusal among
    them; then the codes a client may branch on, and a table of the routes --
    what each reads as a body and answers -- named by method and pattern. The
    module imports ["zod/mini"], whose functions tree-shake. *)

val module_ : ?header:string -> App.t -> (string, string list) result
(** [header] is the comment the module opens with -- what wrote it, and how to
    write it again. [Error] as {!Openapi.document}'s. *)
