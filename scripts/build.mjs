import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { validatePlan } from "./plan-utils.mjs";

const root = resolve(import.meta.dirname, "..");
const destination = resolve(root, "dist");
const files = [
  "index.html",
  "styles.css",
  "app.js",
  "lib.js",
  "crypto-vault.js",
  ".nojekyll",
];

await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
await Promise.all(files.map((file) => cp(resolve(root, file), resolve(destination, file))));

const plansSource = resolve(root, "plans");
const plansDestination = resolve(destination, "plans");
const planFolders = (await readdir(plansSource, { withFileTypes: true }))
  .filter((entry) => entry.isDirectory())
  .sort((a, b) => a.name.localeCompare(b.name));
const catalog = [];

await mkdir(plansDestination, { recursive: true });
for (const folder of planFolders) {
  const sourceFile = resolve(plansSource, folder.name, "plan.json");
  let plan;
  try {
    plan = JSON.parse(await readFile(sourceFile, "utf8"));
  } catch (error) {
    throw new Error(`Could not read plans/${folder.name}/plan.json: ${error.message}`);
  }
  const errors = validatePlan(plan, folder.name);
  if (errors.length) {
    throw new Error(`Invalid plans/${folder.name}/plan.json:\n- ${errors.join("\n- ")}`);
  }
  const planDestination = resolve(plansDestination, folder.name);
  await mkdir(planDestination, { recursive: true });
  await cp(sourceFile, resolve(planDestination, "plan.json"));
  catalog.push({
    id: plan.id,
    name: plan.name,
    description: typeof plan.description === "string" ? plan.description : "",
    path: `./plans/${folder.name}/plan.json`,
  });
}

await writeFile(
  resolve(plansDestination, "index.json"),
  `${JSON.stringify({ schemaVersion: 1, plans: catalog }, null, 2)}\n`,
);

console.log(`Built ${files.length} app files and ${catalog.length} folder plan(s) in ${destination}`);
