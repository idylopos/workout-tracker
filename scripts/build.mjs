import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { validatePlan } from "./plan-utils.mjs";
import { writeWorkoutPlanMarkdown } from "./sync-plan-markdown.mjs";

const root = resolve(import.meta.dirname, "..");
const destination = resolve(root, "dist");
await writeWorkoutPlanMarkdown(root);
const files = [
  "index.html",
  "styles.css",
  "app.js",
  "lib.js",
  "progression.js",
  "load-picker.js",
  "weekly-review.js",
  "review-contract.js",
  "review-storage.js",
  "review-client.js",
  "review-ui.js",
  "review-config.js",
  "crypto-vault.js",
  "unlock-session.js",
  "WORKOUT_PLAN.md",
  ".nojekyll",
];

await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
await Promise.all(files.map((file) => cp(resolve(root, file), resolve(destination, file))));
const endpoint = process.env.AI_REVIEW_ENDPOINT || "";
if (endpoint) {
  const url = new URL(endpoint);
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(local && url.protocol === "http:")) || url.username || url.password ||
    url.search || url.hash || url.pathname !== "/api/weekly-review") {
    throw new Error("AI_REVIEW_ENDPOINT must be an HTTPS /api/weekly-review URL without credentials, query, or fragment (HTTP localhost is allowed for development).");
  }
  const html = await readFile(resolve(destination, "index.html"), "utf8");
  await writeFile(resolve(destination, "index.html"), html.replace("connect-src 'self'", `connect-src 'self' ${url.origin}`));
}
await writeFile(resolve(destination, "review-config.js"), `export const reviewConfig = Object.freeze(${JSON.stringify({ endpoint })});\n`);
await cp(resolve(root, "assets"), resolve(destination, "assets"), { recursive: true });

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
