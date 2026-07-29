import { cp, mkdir, rm } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const destination = resolve(root, "dist");
const files = [
  "index.html",
  "styles.css",
  "app.js",
  "lib.js",
  ".nojekyll",
];

await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
await Promise.all(files.map((file) => cp(resolve(root, file), resolve(destination, file))));

console.log(`Built ${files.length} files in ${destination}`);
