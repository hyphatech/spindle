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

=== "htmlit"

    ```ocaml
    --8<-- "pages/htmlit_page.ml"
    ```

=== "TyXML"

    ```ocaml
    --8<-- "pages/tyxml_page.ml"
    ```

=== "html_of_jsx"

    ```ocaml
    --8<-- "pages/jsx_page.mlx"
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

=== "jingoo"

    ```ocaml
    --8<-- "pages/jingoo_page.ml"
    ```

    ```jinja title="templates/greeting.jingoo"
    --8<-- "pages/templates/greeting.jingoo"
    ```

    jingoo raises on a template it cannot read, so load it when the program
    starts, as above, not per request.

```sh
curl 'localhost:8080/hello/%3Cb%3Ekim%3C%2Fb%3E'
```

```text
<!DOCTYPE html>
<html lang="en"><head>...<title>Hello</title></head><body><h1>Hello, &lt;b&gt;kim&lt;/b&gt;!</h1></body></html>
```

A refusal is still JSON, on a page's route as on any other. For an HTML
page when no route matches, pass your own answer as `~not_found`
([How routes are matched](../tutorial/routes.md#how-routes-are-matched)).
To read a form a page posts, see
[Forms and file uploads](../tutorial/bodies.md#forms-and-file-uploads); a
form posted from another site is refused by the
[cross-site check](cookies.md#csrf-and-cors).
