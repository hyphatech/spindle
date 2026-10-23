// A code block that holds one line, `--8<-- "file"` or `--8<-- "file:part"`,
// is that file from examples/, or the lines of it between
// `--8<-- [start:part]` and `--8<-- [end:part]`, so a page shows only code
// that compiles. A file or a part that is not there fails the build, and
// the markers themselves are never shown.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { defineMdastPlugin } from "satteri";

const include = /^--8<-- "([^":]+)(?::([\w-]+))?"$/;
const marker = /--8<-- \[(start|end):[\w-]+\]/;

const part = (file, lines, name) => {
  const start = lines.findIndex((l) => l.includes(`--8<-- [start:${name}]`));
  const end = lines.findIndex((l) => l.includes(`--8<-- [end:${name}]`));
  if (start < 0 || end < start) throw new Error(`examples/${file} has no part ${name}`);
  return lines.slice(start + 1, end);
};

export default function snippets({ base }) {
  return defineMdastPlugin({
    name: "spindle-snippets",
    code(node, ctx) {
      const m = include.exec(node.value.trim());
      if (!m) return;
      const [, file, name] = m;
      let lines;
      try {
        lines = readFileSync(join(base, file), "utf8").split("\n");
      } catch {
        throw new Error(`examples/${file} is not there`);
      }
      if (name) lines = part(file, lines, name);
      const value = lines
        .filter((l) => !marker.test(l))
        .join("\n")
        .trim();
      ctx.replaceNode(node, { ...node, value });
    },
  });
}
