import esbuild from "esbuild";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const watch = process.argv.includes("--watch");
const prod = process.argv.includes("--prod") || !watch;

const uiTemplatePath = path.join(root, "src", "ui", "template.html");
const distDir = path.join(root, "dist");
const iconPath = path.join(root, "..", "assets", "Lynk.png");

function iconDataUri() {
  const bytes = fs.readFileSync(iconPath);
  return "data:image/png;base64," + bytes.toString("base64");
}

async function buildUiJs() {
  return esbuild.build({
    entryPoints: [path.join(root, "src", "ui", "ui.ts")],
    bundle: true,
    outfile: path.join(distDir, "ui.js"),
    target: "es2017",
    format: "iife",
    logLevel: "silent",
  });
}

function emitHtml() {
  const template = fs.readFileSync(uiTemplatePath, "utf8");
  const uiJs = fs.readFileSync(path.join(distDir, "ui.js"), "utf8");
  const html = template
    .replace("/*__UI_JS__*/", () => uiJs)
    .replaceAll("__LYNK_ICON__", iconDataUri());
  fs.writeFileSync(path.join(distDir, "ui.html"), html);
}

async function buildAll() {
  await esbuild.build({
    entryPoints: [path.join(root, "src", "code.ts")],
    bundle: true,
    outfile: path.join(distDir, "code.js"),
    target: "es2017",
    format: "iife",
    logLevel: "info",
    sourcemap: prod ? false : "inline",
    minify: false,
  });
  await buildUiJs();
  emitHtml();
  console.log("[lynk] figma plugin built → dist/code.js, dist/ui.html");
}

if (watch) {
  const ctx = await esbuild.context({
    entryPoints: [path.join(root, "src", "code.ts")],
    bundle: true,
    outfile: path.join(distDir, "code.js"),
    target: "es2017",
    format: "iife",
    sourcemap: "inline",
  });
  await ctx.watch();
  const ctxUi = await esbuild.context({
    entryPoints: [path.join(root, "src", "ui", "ui.ts")],
    bundle: true,
    outfile: path.join(distDir, "ui.js"),
    target: "es2017",
    format: "iife",
    plugins: [{
      name: "emit-html",
      setup(build) {
        build.onEnd(() => { try { emitHtml(); } catch (e) { console.error(e); } });
      },
    }],
  });
  await ctxUi.watch();
  console.log("[lynk] watching…");
} else {
  await buildAll();
}
