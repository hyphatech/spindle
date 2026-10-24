import { fileURLToPath } from "node:url";
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import { satteri } from "@astrojs/markdown-satteri";
import links from "starlight-links-validator";
import hypha from "starlight-theme-hypha";
import consoleCommands from "./console.mjs";
import snippets from "./snippets.mjs";

// Spindle's documentation site, published to GitHub Pages by
// .github/workflows/docs.yml. `make docs` builds it into site/, odoc's
// reference from the .mli files into public/reference/ first.
//
// Every program a page shows is a file under examples/, built with the
// repository, and included by snippets.mjs -- so a page cannot show code
// that does not compile. A missing one, or a link to a page or a heading
// that is not there, fails the build.
const repository = fileURLToPath(new URL("..", import.meta.url));

export default defineConfig({
  site: "https://hyphatech.github.io",
  base: "/spindle",
  outDir: `${repository}site`,
  markdown: { processor: satteri({ mdastPlugins: [snippets({ base: `${repository}examples` })] }) },
  integrations: [
    starlight({
      title: "spindle",
      description: "The Eio-native web framework for modern OCaml.",
      logo: { src: "starlight-theme-hypha/assets/hypha.webp" },
      favicon: "/favicon.svg",
      plugins: [
        hypha({
          brand: "hypha",
          github: "hyphatech/spindle",
          tabs: { Tutorial: "graduation-cap", Guides: "book-open", Reference: "library" },
          links: [{ label: "Hypha Stack", href: "https://hyphatech.io/stack", icon: "layers" }],
        }),
        // The reference is odoc's, in public/, which the validator cannot see;
        // the tutorial links to the server it has the reader start.
        links({
          components: [["Feature", "href"]],
          errorOnLocalLinks: false,
          exclude: ["**/reference/spindle*/**"],
        }),
      ],
      expressiveCode: { plugins: [consoleCommands()] },
      sidebar: [
        {
          label: "Tutorial",
          items: [
            "install",
            "tutorial/first-app",
            "tutorial/routes",
            "tutorial/dependencies",
            "tutorial/bodies",
            "tutorial/logging",
            "tutorial/static-files",
            "tutorial/database",
            "tutorial/openapi",
            "tutorial/client-schemas",
          ],
        },
        {
          label: "Guides",
          items: [
            "guide/pages",
            "guide/databases",
            "guide/cookies",
            "guide/oauth",
            "guide/mcp",
            "guide/middleware",
            "guide/sse",
            "guide/websockets",
            "guide/client",
            "guide/background",
            "guide/rate-limits",
            "guide/compression",
            "guide/testing",
            "guide/serving",
            "guide/domains",
            "guide/health",
            "guide/metrics",
          ],
        },
        { label: "Reference", items: ["reference"] },
      ],
    }),
  ],
});
