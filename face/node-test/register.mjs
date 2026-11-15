// Runs the Biopass app's frontend unit tests (written for `bun test`) with Node, which SteamOS's repository has
// (bun it has not): node --import <this> --test <files>. Node strips the TypeScript types itself; this resolves
// what bun resolves on its own: `bun:test` (bun-test.mjs here), the app's `@/` alias (tsconfig paths: src/), and
// imports without a file extension.
import { existsSync, statSync } from "node:fs";
import { registerHooks } from "node:module";
import { pathToFileURL } from "node:url";

const shim = new URL("./bun-test.mjs", import.meta.url).href;
const src = `${process.cwd()}/src/`;
const isFile = (path) => existsSync(path) && statSync(path).isFile();
const withExtension = (path) =>
  [path, `${path}.ts`, `${path}.tsx`, `${path}/index.ts`].find(isFile);

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "bun:test") return { url: shim, shortCircuit: true };
    let path = null;
    if (specifier.startsWith("@/")) path = src + specifier.slice(2);
    else if (
      (specifier.startsWith("./") || specifier.startsWith("../")) &&
      context.parentURL?.startsWith("file:")
    ) {
      path = new URL(specifier, context.parentURL).pathname;
    }
    if (path !== null) {
      const file = withExtension(path);
      if (file) return { url: pathToFileURL(file).href, shortCircuit: true };
    }
    return next(specifier, context);
  },
});
