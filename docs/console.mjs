// A console block is commands and what they print, so its copy button
// copies the commands alone, without their `$ ` prompt.
import { definePlugin } from "@expressive-code/core";

// Expressive Code's copy button writes a block's newlines as U+007F.
const newline = "\u007f";

const copyButton = (node) => {
  if (node.tagName === "button" && "dataCode" in (node.properties ?? {})) return node;
  for (const child of node.children ?? []) {
    const button = copyButton(child);
    if (button) return button;
  }
};

export default function consoleCommands() {
  return definePlugin({
    name: "spindle-console",
    hooks: {
      postprocessRenderedBlock({ codeBlock, renderData }) {
        if (codeBlock.language !== "console") return;
        const button = copyButton(renderData.blockAst);
        if (!button) return;
        button.properties.dataCode = codeBlock.code
          .split("\n")
          .filter((l) => l.startsWith("$ "))
          .map((l) => l.slice(2))
          .join(newline);
      },
    },
  });
}
