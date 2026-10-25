# Bounded inputs: a parameter's range in its codec

**Status: Accepted** — the whole shape is signed off; nothing is built.
Date: 2026-10-25

## The problem

A JSON body's member can be bounded and a request's other inputs cannot, so
the commonest parameter an API has -- a page size between 1 and 100 -- is
checked by hand and described as having no bounds.

- **A codec has no place for a bound.** `Codec.shape` is `String | Format |
  Integer | Number | Boolean | Enum` (`core/codec_repr.mli`), and a
  `Codec.custom` is "described as a string". A path segment, a query
  parameter, a header, a cookie and a form's field are all read by a codec,
  so none of them can say `1 ≤ per_page ≤ 100`. A body can:
  `Wiretype.int_bounded ~min:1 ~max:100 ()` refuses `0` as `too_small` and
  prints `minimum: 1` in the document.
- **The documented way checks by hand, and the document says nothing.** The
  dependencies tutorial's paging (`examples/dependencies.ml`) reads `page` and
  `per_page` as plain `Codec.int` and checks them in a `Dep.join`, eight
  lines for two bounds. The OpenAPI document calls both unbounded integers,
  so a generated client sends `per_page=0` without complaint. The example
  has no upper bound at all: `per_page=1000000000` is accepted.
- **Every framework of its kind has it.** FastAPI's `Query(ge=1, le=100)`,
  `Path(gt=0)` and `max_length` are on most routes it serves, checked and
  written into the document by the same declaration. That one declaration
  is checked, documented and printed is Spindle's own promise, kept for
  bodies and broken for everything else.

Asked for by the owner on 2026-10-25, measuring Spindle against FastAPI:
"i was sure it's covered. please do if not."

## Scope

In it, in `spindle` alone:

- Bounded codecs for a whole number, a 64-bit one, a float and a string's
  length, read the same way at every place a codec reads: path, query,
  header, cookie, form field, and each value of a `list` input.
- The bound's refusal, its problem code, and the description of it in the
  OpenAPI document and the Melange client.
- `App.make` refusing a default its codec's bounds would refuse.

Not in it:

- **A pattern** (FastAPI's `pattern=`). Wiretype has none, and Spindle links
  no regular-expression engine; a pattern the server reads with OCaml's and
  a client with JavaScript's is one value read two ways, which *A value with
  structure is read by its parser* exists to prevent. A closed set is
  `Codec.enum`; anything else is `Codec.custom`.
- **How many values a `list` input takes.** A bound on each value is in; the
  count is a shape of its own (`min_items`), left until asked for.
- **Bounds on `date`, `instant`, `uuid` or a custom codec.** A custom codec's
  parse already refuses what it likes; describing what it refuses in the
  document is a `Codec.custom ~shape` of its own, not this work.
- The Zod printer, which prints bodies and answers, never parameters.

## User scenarios

1. **A page size bounded where it is read.**
   `Query.default "per_page" (Codec.int_bounded ~min:1 ~max:100 ()) 10`,
   with no `Dep.join`.
   *Accepted when* `per_page=0` is a `400` with the problem
   `{"at":"query.per_page","code":"too_small"}`, `per_page=101` one with
   `too_large`, `per_page=abc` one with `malformed` as today, and
   `per_page=50` reaches the handler as `50`.
2. **The document says what the codec checks.** *Accepted when* that
   parameter's schema in the OpenAPI document is
   `{"type":"integer","minimum":1,"maximum":100,"default":10}`, and the
   Melange client's component for it carries the same bounds.
3. **A string's length.**
   `Header.required "x-tag" (Codec.string_bounded ~max_length:64 ())`.
   *Accepted when* a value of 65 code points is `too_long` at `header.x-tag`,
   one of 64 code points written in 128 bytes is read, and the document
   says `maxLength: 64`.
4. **Every problem at once.** *Accepted when* `?page=0&per_page=500` is one
   refusal listing both problems, as two malformed parameters are today.
5. **A mistake is caught before a request is.** *Accepted when*
   `Codec.int_bounded ~min:10 ~max:1 ()` raises `Invalid_argument` where it
   is made, and a route whose `Query.default` is outside its codec's bounds
   is refused by `App.make`, its sentence naming the route and the input.
6. **Nothing else moves.** *Accepted when* every existing test passes
   unchanged and every committed OpenAPI document and printed client is
   written byte for byte as before.

## Requirements

- **FR-1.** A codec can bound a whole number, a 64-bit one and a float by
  what wiretype bounds each by, and a string by its length in code points.
- **FR-2.** A value its codec reads but its bounds refuse is a problem at its
  input's place, with the code wiretype gives that bound in a body, and is
  reported with the request's other problems.
- **FR-3.** One bounded codec reads the same wherever it is used: a path
  segment, a query parameter, a header, a cookie, a form's field, and each
  value of a list.
- **FR-4.** The OpenAPI document and the Melange client describe a
  parameter's bounds as they describe a body member's.
- **FR-5.** A default outside its codec's bounds is refused when the app is
  made.
- **FR-6.** Bounds that contradict each other are refused where the codec is
  made.
- **FR-7.** A codec with no bounds reads, refuses and is described exactly as
  it is today.

## Design

### The codecs

Spelt as wiretype spells the same bounds, so one word means one thing on a
body's member and on a parameter:

```ocaml
val int_bounded : ?min:int -> ?max:int -> ?multiple_of:int -> unit -> int t
val int64_bounded :
  ?min:int64 -> ?max:int64 -> ?multiple_of:int64 -> unit -> int64 t
val float_bounded :
  ?min:float -> ?max:float -> ?above:float -> ?below:float ->
  ?multiple_of:float -> unit -> float t
val string_bounded : ?min_length:int -> ?max_length:int -> unit -> string t
```

Each reads its text as its unbounded twin does (`int`, `int64`, `float`,
`string`), then holds the value to its bounds, and raises `Invalid_argument`
where wiretype's raises: `min` above `max`, a negative length, a
`multiple_of` that is not positive. A route reads it as any codec, and the
paging of the tutorial becomes:

```ocaml
let paging =
  let+ page =
    Spindle.Query.default "page" (Spindle.Codec.int_bounded ~min:1 ()) 1
  and+ per_page =
    Spindle.Query.default "per_page"
      (Spindle.Codec.int_bounded ~min:1 ~max:100 ())
      10
  in
  { page; per_page }
```

### The shape carries its bounds

`Codec.shape`'s constructors carry what the printers already read for a body,
`Wiretype.Schema`'s records:

```ocaml
type shape =
  | String of Wiretype.Schema.Text.t   (* its length; words and format none *)
  | Format of Wiretype.Shape.format
  | Integer of Wiretype.Schema.Number.t
  | Number of Wiretype.Schema.Number.t
  | Boolean
  | Enum of string list
```

`Described.of_shape` hands the bounds to `Wiretype.Schema` as they are, and
the OpenAPI and Melange printers, which write `minimum`, `maximum` and
`maxLength` for a body already, write them for a parameter with no change of
their own. An unbounded codec carries `Number.any` and `Text.any`, so its
description is what it was (FR-7). A whole number's bound is a float in the
record, as it is for a body: exact to 2^53, where a JavaScript client stops
holding the number anyway.

### The refusal

A codec's repr gains a check apart from its parse, whose failure is a code
and a sentence. `Input.parse` answers `malformed` when the parse fails, as
now, and the check's code when the bounds do -- `too_small`, `too_large`,
`not_a_multiple`, `too_short`, `too_long`, wiretype's words through
`Wiretype.Problem.code_to_string` -- in a sentence that says what the value
must be ("This is 100 or less."), never quoting it. `Codec.parse`, which an
application calls itself, answers either failure as its sentence.

A path segment its bounds refuse is what its `~unparsed` says, as one its
codec cannot read is: `400` at `path.<name>` by default, the next route under
`Next_route`.

### A default is checked when the app is made

`App.make` already walks every input it describes; it runs each default
through its codec's check, and refuses the route table where one fails, with
a sentence naming the route and the input, as it refuses a route table that
is wrong in any other way.

### One name, one code, one meaning

Settled with the owner on 2026-10-25: "api must remain coherent and
consistent". A bound reads the same on a body's member and on a parameter:
wiretype's names, wiretype's codes, and a value its bounds refuse is one its
codec refused, `~unparsed` and all.

### Alternatives rejected

- **Names of Spindle's own**, `int_between`: a second word for wiretype's
  `int_bounded`.
- **`malformed` for every refused parameter**: a client would branch on
  `too_large` for a member and on something else for a parameter.

- **Bounds as labels on the input**, `Query.optional ~min:1 "page"
  Codec.int`. Five input modules, each with a label for every bound of every
  type, typed so `~max_length` cannot reach an `int`; and the same bound
  written again at each place one value is read. A bound is the value's, so
  it is the codec's.
- **`Codec.int ~min ~max ()`**, the bounds on the plain codec. Every caller
  of `Codec.int` today would write `()` after it for nothing, and it spells
  the same thing otherwise than wiretype does.
- **A refinement, `Codec.check : ('a -> (unit, string) result) -> 'a t -> 'a
  t`.** It says nothing a document can print, so it is `Dep.join` again with
  the problem moved; a check of the application's own is a `custom` codec
  already.
- **A codec made from a wiretype description**, one declaration for a body
  and a parameter. A description reads JSON and a parameter is text: `abc`
  is no JSON at all, so every read would quote first, and a description can
  be an object, which no parameter is.

## Rules it adds

The rule **`invalid_arg` is raised in these places alone** gains
`Spindle.Codec.int_bounded`, `int64_bounded`, `float_bounded` and
`string_bounded`, for bounds that contradict each other: a constant written in
source, so a program that starts never meets one.

## Stages

- [ ] **Bounded codecs.** The four codecs and their `.mli`; the shape with its
  bounds; the check and its codes in `Input.parse`; `App.make`'s check of a
  default; rows in `test_spindle` for each code at each place and in
  `test_openapi` for the document, with a QCheck property that a value is
  read exactly when it is within its bounds; `examples/dependencies.ml`'s
  paging read through bounded codecs, and the tutorial pages that show it;
  the rule's new places in `AGENTS.md`; `CHANGES.md`.

## Verification

`make test` and `make lint` pass. Scenarios 1 to 5 are rows of
`test_spindle` and `test_openapi`, and scenario 6 is every committed
document and client written again unchanged. By hand, the dependencies
example served and asked with `curl` for `per_page` of `0`, `101`, `abc` and
`50`, and its document read in Scalar, showing both bounds.

## Where the facts go

| A fact | Its owner |
|---|---|
| The codecs, the shape, the codes | `core/codec.mli`, `core/input.mli` |
| How to bound an input | `docs/src/content/docs/tutorial/routes.md`, beside the codecs, and `tutorial/dependencies.md`'s paging, its program `examples/dependencies.ml` |
| The new `invalid_arg` places | *Rules that must hold* in `AGENTS.md` |
| What changed for a user, the shape's constructors among it | `CHANGES.md`, under `## Unreleased` |
| Why, and the alternatives | the commit message |
