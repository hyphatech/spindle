# HTML pages and templates

A page is a string. `Returns.html` answers it at `200` as
`text/html; charset=utf-8`; `Response.html` does the same under any status.
Spindle has no template language: render with whichever library you like.
**Escaping what a person sent is the renderer's job**, and each of these
escapes text unless told not to.

| Renderer | How you write a page | Turning a page into a string |
|---|---|---|
| [htmlit](https://erratique.ch/software/htmlit) | combinators, no dependencies | `Htmlit.El.to_string ~doctype:true page` |
| [TyXML](https://github.com/ocsigen/tyxml) | combinators, or HTML through `tyxml-ppx`, checked against the standard as it compiles | `Format.asprintf "%a" (Tyxml.Html.pp ()) page` |
| [html_of_jsx](https://github.com/davesnx/html_of_jsx) | JSX, in the [mlx](https://github.com/ocaml-mlx/mlx) dialect | `"<!doctype html>" ^ JSX.render page` |
| [jingoo](https://github.com/tategakibunko/jingoo) | Jinja templates, in files | `Jingoo.Jg_template.Loaded.eval template ~models` |

Each program serves the same page at `/hello/{name}`:

**htmlit**

```ocaml
(* A page made with htmlit: combinators, and no dependency of their own.

   Spindle has no template language: [Returns.html] answers the string a
   renderer made, so any renderer fits, and escaping what a person sent is
   the renderer's -- [El.txt] escapes, so the <b>kim</b> of
   /hello/%3Cb%3Ekim%3C%2Fb%3E is words on the page. *)

open Spindle.Syntax
module El = Htmlit.El

let name = Spindle.Path.string "name"

let greeting name =
  El.page ~lang:"en" ~title:"Hello"
    (El.body [ El.h1 [ El.txt ("Hello, " ^ name ^ "!") ] ])

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello" / name)
      Spindle.Returns.html
      (let+ name = Spindle.param name in
       Ok (El.to_string ~doctype:true (greeting name)));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
```

**TyXML**

```ocaml
(* A page made with TyXML, written as HTML through its ppx: the markup is
   checked against the standard as it compiles, so a [p] inside a [ul] is a
   type error.

   Spindle has no template language: [Returns.html] answers the string a
   renderer made, so any renderer fits, and escaping what a person sent is
   the renderer's -- TyXML escapes text as it prints, so the <b>kim</b> of
   /hello/%3Cb%3Ekim%3C%2Fb%3E is words on the page. *)

open Spindle.Syntax
module Html = Tyxml.Html

let name = Spindle.Path.string "name"

let greeting name =
  let hello = "Hello, " ^ name ^ "!" in
  [%html
    {|<html lang="en">
        <head><title>Hello</title></head>
        <body><h1>|}
      [ Html.txt hello ]
      {|</h1></body>
      </html>|}]

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello" / name)
      Spindle.Returns.html
      (let+ name = Spindle.param name in
       Ok (Format.asprintf "%a" (Html.pp ()) (greeting name)));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
```

**html_of_jsx**

```ocaml
(* A page made with html_of_jsx, written as JSX in mlx, an OCaml dialect
   dune reads through the dialect in this package's dune-project.

   Spindle has no template language: [Returns.html] answers the string a
   renderer made, so any renderer fits, and escaping what a person sent is
   the renderer's -- [JSX.string] escapes, so the <b>kim</b> of
   /hello/%3Cb%3Ekim%3C%2Fb%3E is words on the page. *)

open Spindle.Syntax

let name = Spindle.Path.string "name"

let greeting name =
  <html lang="en">
    <head><title>(JSX.string "Hello")</title></head>
    <body><h1>(JSX.string ("Hello, " ^ name ^ "!"))</h1></body>
  </html>

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello" / name)
      Spindle.Returns.html
      (let+ name = Spindle.param name in
       Ok ("<!doctype html>" ^ JSX.render (greeting name)));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
```

dune reads mlx through a dialect, declared once in your
`dune-project` with `mlx-pp` from the `mlx` package:

```lisp
(dialect
 (name mlx)
 (implementation
  (extension mlx)
  (preprocess
   (run mlx-pp %{input-file}))))
```

**jingoo**

```ocaml
(* A page made with jingoo, from a template file in Jinja's syntax:
   templates/greeting.jingoo, read once when the program starts and rendered
   for every request. Run it from the repository's root, as every example
   is.

   Spindle has no template language: [Returns.html] answers the string a
   renderer made, so any renderer fits, and escaping what a person sent is
   the renderer's -- jingoo escapes every value it writes unless told not
   to, so the <b>kim</b> of /hello/%3Cb%3Ekim%3C%2Fb%3E is words on the
   page. *)

open Spindle.Syntax
module Jg_template = Jingoo.Jg_template
module Jg_types = Jingoo.Jg_types

let name = Spindle.Path.string "name"

let greeting =
  Jg_template.Loaded.from_file "examples/pages/templates/greeting.jingoo"

let routes =
  [
    Spindle.get
      Spindle.Path.(s "hello" / name)
      Spindle.Returns.html
      (let+ name = Spindle.param name in
       Ok
         (Jg_template.Loaded.eval greeting
            ~models:[ ("name", Jg_types.Tstr name) ]));
  ]

let () =
  Spindle.Log.setup ();
  Eio_main.run @@ fun env -> Spindle.serve env routes
```

```jinja title="templates/greeting.jingoo"
<!doctype html>
<html lang="en">
  <head><title>Hello</title></head>
  <body><h1>Hello, {{ name }}!</h1></body>
</html>
```

jingoo raises on a template it cannot read, so load it when the program
starts, as above, not per request.

```console
$ curl localhost:8080/hello/kim
<!DOCTYPE html>
<html lang="en"><head>...<title>Hello</title></head><body><h1>Hello, kim!</h1></body></html>
```

A name with markup in it is escaped: visit `/hello/<b>kim</b>` and the
page reads `Hello, <b>kim</b>!`, tags and all, rather than a bold name.

A refusal is still JSON, on a page's route as on any other. For an HTML
page when no route matches, pass your own answer as `~not_found`
([How routes are matched](../tutorial/routes.md#how-routes-are-matched)).
To read a form a page posts, see
[Forms and file uploads](../tutorial/bodies.md#forms-and-file-uploads); a
form posted from another site is refused by the
[cross-site check](cookies.md#csrf-and-cors).
