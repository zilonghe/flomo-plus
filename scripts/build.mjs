import { copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = new URL("../", import.meta.url);
const dist = new URL("dist/", root);
const paths = {
  "/": ["index.html", "text/html; charset=utf-8"],
  "/app.js": ["app.js", "text/javascript; charset=utf-8"],
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
const bundle = server
  .replace(marker, () => `const assets = ${JSON.stringify(assets)};`)
  .replace(weReadImport, () => bundledWeRead);

await rm(dist, { recursive: true, force: true });
await mkdir(new URL("server/", dist), { recursive: true });
await mkdir(new URL(".openai/", dist), { recursive: true });
await writeFile(new URL("server/index.js", dist), bundle);
await copyFile(new URL(".openai/hosting.json", root), new URL(".openai/hosting.json", dist));
console.log(`Built ${fileURLToPath(dist)}`);
