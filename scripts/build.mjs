import { copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = new URL("../", import.meta.url);
const dist = new URL("dist/", root);
const paths = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/app.js": ["app.js", "text/javascript; charset=utf-8"],
  "/ux-helpers.js": ["ux-helpers.js", "text/javascript; charset=utf-8"],
  "/crypto.js": ["crypto.js", "text/javascript; charset=utf-8"],
  "/flomo.js": ["flomo.js", "text/javascript; charset=utf-8"],
  "/weread.js": ["weread.js", "text/javascript; charset=utf-8"],
  "/styles.css": ["styles.css", "text/css; charset=utf-8"],
  "/relay/server.mjs": ["../relay/server.mjs", "application/octet-stream"],
  "/relay/README.md": ["../relay/README.md", "text/plain; charset=utf-8"],
};

const assets = Object.fromEntries(await Promise.all(
  Object.entries(paths).map(async ([route, [file, type]]) => [
    route, { type, body: await readFile(new URL(`public/${file}`, root), "utf8") }
  ])
));

const marker = /import\s*\{\s*assets\s*\}\s*from\s*["']\.\/assets\.generated\.js["'];?/;
const server = await readFile(new URL("src/index.js", root), "utf8");
if (!marker.test(server)) throw new Error("Worker assets import is missing");
const weReadImport = /^import \{ WeReadError, listWeReadBooks, listWeReadNotes \} from "\.\/weread\.js";$/m;
if (!weReadImport.test(server)) throw new Error("Worker WeRead import is missing");
const weRead = await readFile(new URL("src/weread.js", root), "utf8");
const bundledWeRead = `const { WeReadError, listWeReadBooks, listWeReadNotes } = (() => {
${weRead.replace(/^export (?=(?:async function|class) )/gm, "")}
return { WeReadError, listWeReadBooks, listWeReadNotes };
})();`;
const retrievalImport = /^import \{([^}]+)\} from "\.\/retrieval\.js";$/m;
const insightImport = /^import \{([^}]+)\} from "\.\/insights\.js";$/m;
const names = (source, marker) => {
  const imported = source.match(marker)?.[1];
  if (!imported) throw new Error("Worker import is missing: " + marker);
  return imported.split(",").map(name => name.trim()).filter(Boolean);
};
const insights = await readFile(new URL("src/insights.js", root), "utf8");
const retrieval = await readFile(new URL("src/retrieval.js", root), "utf8");
const retrievalNames = [...new Set([...names(server, retrievalImport), ...names(insights, retrievalImport)])];
const retrievalExports = new Set([...retrieval.matchAll(/^export function (\w+)/gm)].map(match => match[1]));
for (const name of retrievalNames) {
  if (!retrievalExports.has(name)) throw new Error("Unbundled retrieval symbol: " + name);
}
const bundledRetrieval = `const {${retrievalNames}} = (() => {
${retrieval.replace(/^export (?=function )/gm, "")}
return {${retrievalNames}};
})();`;
const insightNames = names(server, insightImport);
const bundledInsights = `const {${insightNames}} = (() => {
${insights.replace(retrievalImport, "").replace(/^export (?=(?:async function|function|const) )/gm, "")}
return {${insightNames}};
})();`;
const bundle = server
  .replace(marker, () => `const assets = ${JSON.stringify(assets)};`)
  .replace(weReadImport, () => bundledWeRead)
  .replace(retrievalImport, () => bundledRetrieval)
  .replace(insightImport, () => bundledInsights);

await rm(dist, { recursive: true, force: true });
await mkdir(new URL("server/", dist), { recursive: true });
await mkdir(new URL(".openai/", dist), { recursive: true });
await writeFile(new URL("server/index.js", dist), bundle);
await copyFile(new URL(".openai/hosting.json", root), new URL(".openai/hosting.json", dist));
console.log(`Built ${fileURLToPath(dist)}`);
