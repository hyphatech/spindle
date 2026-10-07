# Pages

**A page is a string.** `Returns.html` answers it at `200` as
`text/html; charset=utf-8`, and `Response.html` under any status. Spindle
has no template language and writes no HTML of its own: rendering a page is
a problem well solved elsewhere, so an application renders with the library
it likes, and **escaping what a person sent is that renderer's job**. Each
of these escapes the text it writes unless it is told not to, and
each program below serves one page with one of them:

| Renderer | How a page is written | Its string |
|---|---|---|
| [htmlit](https://erratique.ch/software/htmlit) | combinators, with no dependency of their own | `Htmlit.El.to_string ~doctype:true page` |
| [TyXML](https://github.com/ocsigen/tyxml) | combinators, or HTML through `tyxml-ppx`; the markup is checked against the standard as it compiles | `Format.asprintf "%a" (Tyxml.Html.pp ()) page` |
| [html_of_jsx](https://github.com/davesnx/html_of_jsx) | JSX, in the [mlx](https://github.com/ocaml-mlx/mlx) dialect | `"<!doctype html>" ^ JSX.render page` |
| [jingoo](https://github.com/tategakibunko/jingoo) | Jinja's templates, in files | `Jingoo.Jg_template.Loaded.eval template ~models` |

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

=== "jingoo"

    ```ocaml
    --8<-- "pages/jingoo_page.ml"
    ```

    ```jinja title="templates/greeting.jingoo"
    --8<-- "pages/templates/greeting.jingoo"
    ```

jingoo reads a template when it is loaded and raises on one it cannot, so
a template is loaded as the program starts, where the raise stops it; a
variable a template names and the model lacks is written as nothing. A
refusal is JSON on every route, a page's included.

