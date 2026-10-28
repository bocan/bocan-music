#!/usr/bin/env node
// check-links.mjs: fail the build when the generated site links to itself badly.
//
// Walks the built site (default `_site`) and checks every internal reference:
//   - HTML: href, src, srcset and poster attributes, plus the og:/twitter:
//     meta URLs, including `#fragment` targets against the ids on the page.
//   - CSS: url(...) references, relative to the stylesheet.
//   - XML and text files (sitemap, appcast feeds, robots.txt): absolute URLs
//     on the site's own origin.
//
// A link is internal when it is relative, root-absolute, or absolute on the
// site's origin (`url` in src/_data/site.json, or --origin). External links
// are counted but never fetched: the check runs offline and in CI, and a
// third-party outage must not block a deploy.
//
// A path resolves the way GitHub Pages serves it: the file itself, a
// directory's index.html, or the path plus `.html`.
//
// Usage: node scripts/check-links.mjs [siteDir] [--origin https://example.org]
// Exit status: 0 clean, 1 broken links found, 2 usage error.
//
// Zero dependencies on purpose; Node 20 or later (CI's ubuntu image ships 20).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

// Meta tags whose `content` is a URL worth checking when it is on our origin.
const META_URL_KEYS = new Set([
  "og:url",
  "og:image",
  "og:image:secure_url",
  "twitter:image",
]);

// Schemes that are never files on this site.
const SKIPPED_SCHEMES = /^(mailto|tel|javascript|data|sms|blob):/i;

const TAG_RE =
  /<([a-zA-Z][\w:-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*\/?>/g;
const ATTR_RE =
  /([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
const CSS_URL_RE = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)/g;

function usage(message) {
  console.error(`check-links: ${message}`);
  console.error(
    "usage: node scripts/check-links.mjs [siteDir] [--origin https://example.org]",
  );
  process.exit(2);
}

function parseArgs(argv) {
  let siteDir = "_site";
  let origin = null;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--origin") {
      origin = argv[++i];
      if (!origin) usage("--origin needs a value");
    } else if (arg.startsWith("--")) {
      usage(`unknown option ${arg}`);
    } else {
      siteDir = arg;
    }
  }
  if (!origin) {
    const siteData = path.join(SCRIPT_DIR, "..", "src", "_data", "site.json");
    try {
      origin = JSON.parse(fs.readFileSync(siteData, "utf8")).url;
    } catch (error) {
      usage(`cannot read the site origin from ${siteData}: ${error.message}`);
    }
  }
  try {
    origin = new URL(origin).origin;
  } catch {
    usage(`not a valid origin: ${origin}`);
  }
  return { siteDir: path.resolve(siteDir), origin };
}

function walk(dir) {
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) files.push(...walk(full));
    else if (entry.isFile()) files.push(full);
  }
  return files;
}

function decodeEntities(value) {
  return value.replace(/&(#x[0-9a-f]+|#[0-9]+|amp|quot|apos|lt|gt);/gi, (m, e) => {
    const lower = e.toLowerCase();
    if (lower.startsWith("#x")) return String.fromCodePoint(parseInt(lower.slice(2), 16));
    if (lower.startsWith("#")) return String.fromCodePoint(parseInt(lower.slice(1), 10));
    return { amp: "&", quot: '"', apos: "'", lt: "<", gt: ">" }[lower];
  });
}

// Blank out comments, scripts and styles with spaces, keeping newlines, so
// their contents are not parsed as tags but offsets still map to line numbers.
function maskNonMarkup(html) {
  const blank = (m) => m.replace(/[^\n]/g, " ");
  return html
    .replace(/<!--[\s\S]*?-->/g, blank)
    .replace(/(<script\b[^>]*>)([\s\S]*?)(<\/script\s*>)/gi, (m, a, body, b) => a + blank(body) + b)
    .replace(/(<style\b[^>]*>)([\s\S]*?)(<\/style\s*>)/gi, (m, a, body, b) => a + blank(body) + b);
}

function lineAt(text, offset) {
  let line = 1;
  for (let i = 0; i < offset; i++) if (text.charCodeAt(i) === 10) line++;
  return line;
}

function parseAttributes(source) {
  const attrs = new Map();
  for (const m of source.matchAll(ATTR_RE)) {
    const name = m[1].toLowerCase();
    if (attrs.has(name)) continue;
    const raw = m[2] ?? m[3] ?? m[4] ?? "";
    attrs.set(name, decodeEntities(raw));
  }
  return attrs;
}

// Returns { ids, refs } for one HTML document. Each ref is { url, line }.
export function scanHtml(html) {
  const masked = maskNonMarkup(html);
  const ids = new Set();
  const refs = [];
  for (const m of masked.matchAll(TAG_RE)) {
    const tag = m[1].toLowerCase();
    const attrs = parseAttributes(m[2] || "");
    const line = lineAt(masked, m.index);
    if (attrs.has("id")) ids.add(attrs.get("id"));
    if (tag === "a" && attrs.has("name")) ids.add(attrs.get("name"));

    for (const name of ["href", "src", "poster"]) {
      const value = attrs.get(name);
      if (value !== undefined) refs.push({ url: value.trim(), line });
    }
    const srcset = attrs.get("srcset");
    if (srcset) {
      for (const candidate of srcset.split(",")) {
        const url = candidate.trim().split(/\s+/)[0];
        if (url) refs.push({ url, line });
      }
    }
    if (tag === "meta") {
      const key = (attrs.get("property") || attrs.get("name") || "").toLowerCase();
      if (META_URL_KEYS.has(key) && attrs.get("content")) {
        refs.push({ url: attrs.get("content").trim(), line, absoluteOnly: true });
      }
    }
  }
  return { ids, refs };
}

export function scanCss(css) {
  const refs = [];
  const masked = css.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  for (const m of masked.matchAll(CSS_URL_RE)) {
    const url = (m[1] ?? m[2] ?? m[3] ?? "").trim();
    if (url) refs.push({ url, line: lineAt(masked, m.index) });
  }
  return refs;
}

export function scanText(text, origin) {
  const escaped = origin.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`${escaped}(?:/[^\\s"'<>]*)?`, "g");
  return [...text.matchAll(re)].map((m) => ({
    url: m[0],
    line: lineAt(text, m.index),
    absoluteOnly: true,
  }));
}

// URL path of a file in the site, the way a browser would see it.
function pageUrlFor(siteDir, file) {
  const rel = path.relative(siteDir, file).split(path.sep).join("/");
  if (rel === "index.html") return "/";
  if (rel.endsWith("/index.html")) return `/${rel.slice(0, -"index.html".length)}`;
  return `/${rel}`;
}

// Resolves a URL path to a file under siteDir, or null when nothing serves it.
export function resolvePath(siteDir, urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath);
  } catch {
    return null;
  }
  const target = path.join(siteDir, decoded);
  if (target !== siteDir && !target.startsWith(siteDir + path.sep)) return null;
  const candidates = decoded.endsWith("/")
    ? [path.join(target, "index.html")]
    : [target, path.join(target, "index.html"), `${target}.html`];
  for (const candidate of candidates) {
    try {
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // Not this candidate; try the next.
    }
  }
  return null;
}

export function checkSite(siteDir, origin) {
  const files = walk(siteDir);
  const idsByFile = new Map();
  const refsByFile = new Map();

  for (const file of files) {
    const ext = path.extname(file).toLowerCase();
    if (ext === ".html" || ext === ".htm") {
      const { ids, refs } = scanHtml(fs.readFileSync(file, "utf8"));
      idsByFile.set(file, ids);
      refsByFile.set(file, refs);
    } else if (ext === ".css") {
      refsByFile.set(file, scanCss(fs.readFileSync(file, "utf8")));
    } else if (ext === ".xml" || ext === ".txt") {
      refsByFile.set(file, scanText(fs.readFileSync(file, "utf8"), origin));
    }
  }

  const broken = [];
  let internal = 0;
  let external = 0;

  for (const [file, refs] of refsByFile) {
    const base = new URL(pageUrlFor(siteDir, file), origin);
    const source = path.relative(siteDir, file);
    for (const ref of refs) {
      if (!ref.url || SKIPPED_SCHEMES.test(ref.url)) continue;
      let url;
      try {
        url = new URL(ref.url, base);
      } catch {
        broken.push({ source, line: ref.line, url: ref.url, reason: "malformed URL" });
        continue;
      }
      if (!/^https?:$/.test(url.protocol)) continue;
      if (url.origin !== origin) {
        external++;
        continue;
      }
      if (ref.absoluteOnly && !/^https?:\/\//i.test(ref.url)) continue;
      internal++;

      const target = resolvePath(siteDir, url.pathname);
      if (!target) {
        broken.push({ source, line: ref.line, url: ref.url, reason: "no such page or file" });
        continue;
      }
      const fragment = url.hash.slice(1);
      if (!fragment || fragment === "top") continue;
      const ids = idsByFile.get(target);
      if (!ids) continue; // Fragments into non-HTML files are not ours to judge.
      // Browsers try the fragment as written, then percent-decoded (HTML
      // "find a potential indicated element"). markdown-it-anchor writes
      // percent-encoded ids, so both forms occur.
      let decoded = fragment;
      try {
        decoded = decodeURIComponent(fragment);
      } catch {
        // Keep the raw form only.
      }
      if (!ids.has(fragment) && !ids.has(decoded)) {
        broken.push({ source, line: ref.line, url: ref.url, reason: `no element with id "${decoded}"` });
      }
    }
  }

  return { files: files.length, internal, external, broken };
}

function main() {
  const { siteDir, origin } = parseArgs(process.argv.slice(2));
  let stat;
  try {
    stat = fs.statSync(siteDir);
  } catch {
    usage(`${siteDir} does not exist; run the build first`);
  }
  if (!stat.isDirectory()) usage(`${siteDir} is not a directory`);

  const result = checkSite(siteDir, origin);
  for (const b of result.broken) {
    console.error(`${b.source}:${b.line}: ${b.url} (${b.reason})`);
  }
  const summary =
    `${result.files} files, ${result.internal} internal links checked, ` +
    `${result.external} external links skipped`;
  if (result.broken.length > 0) {
    console.error(`check-links: ${result.broken.length} broken link(s). ${summary}.`);
    process.exit(1);
  }
  console.log(`check-links: clean. ${summary}.`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
