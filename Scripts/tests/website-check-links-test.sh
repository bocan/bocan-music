#!/usr/bin/env bash
# Tests for website/scripts/check-links.mjs, hermetic via a fixture site and --origin.
# Run: Scripts/tests/website-check-links-test.sh   (also `make test-scripts`; CI runs it on Linux)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/website/scripts/check-links.mjs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ORIGIN="https://example.test"

command -v node >/dev/null || { echo "website-check-links-test.sh: node is required" >&2; exit 1; }

failures=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

# run_case name expected_exit expected_fragment [site_dir]
run_case() {
    local name="$1" expected_exit="$2" fragment="$3" site="${4:-$SITE}"
    local out exit_code=0
    out="$(node "$SCRIPT" "$site" --origin "$ORIGIN" 2>&1)" || exit_code=$?
    if [[ "$exit_code" -ne "$expected_exit" ]]; then
        fail "$name (exit $exit_code, expected $expected_exit)"
        echo "    output: $out" >&2
        return
    fi
    if [[ -n "$fragment" && "$out" != *"$fragment"* ]]; then
        fail "$name (output missing '$fragment')"
        echo "    output: $out" >&2
        return
    fi
    pass "$name"
}

# A clean fixture site that uses every link form the checker understands.
SITE="$WORK/site"
mkdir -p "$SITE/docs" "$SITE/assets/css" "$SITE/assets/img"
: > "$SITE/assets/img/logo.png"
: > "$SITE/assets/img/logo@2x.png"
: > "$SITE/assets/img/bg.svg"
: > "$SITE/assets/img/poster.jpg"
: > "$SITE/legacy.html"

cat > "$SITE/index.html" <<'HTML'
<!doctype html>
<html>
  <head>
    <meta property="og:image" content="https://example.test/assets/img/logo.png" />
    <meta property="og:url" content="https://example.test/" />
    <link rel="stylesheet" href="/assets/css/main.css" />
    <link rel="me" href="https://elsewhere.test/@someone">
  </head>
  <body>
    <h2 id="%5Bunreleased%5D"><a href="#%5Bunreleased%5D">Unreleased</a></h2>
    <h2 id="caf&#xe9;">Café</h2>
    <a href="docs/">Docs, relative</a>
    <a href="/docs">Docs, no trailing slash</a>
    <a href="/docs/#install">Docs install section</a>
    <a href="/legacy">Pages serves legacy.html</a>
    <a href="https://example.test/docs/?ref=home">Own origin, absolute, query</a>
    <a href="#caf%C3%A9">Encoded fragment of a decoded id</a>
    <a href="#top">Back to top</a>
    <a href="#">Bare hash</a>
    <a href="mailto:someone@example.test">Mail</a>
    <a href="https://elsewhere.test/missing">External, never fetched</a>
    <img src="assets/img/logo.png" srcset="/assets/img/logo.png 1x, /assets/img/logo@2x.png 2x" alt="">
    <video poster="/assets/img/poster.jpg"></video>
    <!-- <a href="/commented-out">ignored</a> -->
    <script>document.write('<a href="/from-script">ignored</a>');</script>
    <pre>&lt;a href="/escaped-in-text"&gt;</pre>
  </body>
</html>
HTML

cat > "$SITE/docs/index.html" <<'HTML'
<!doctype html>
<html><body>
  <h2 id="install">Install</h2>
  <a href="../">Home</a>
  <a href="../index.html#%5Bunreleased%5D">Unreleased on home</a>
</body></html>
HTML

cat > "$SITE/assets/css/main.css" <<'CSS'
body { background: url("../img/bg.svg"); }
.logo { background-image: url(/assets/img/logo.png); }
.data { background: url(data:image/png;base64,AAAA); }
/* .old { background: url(../img/gone.png); } */
CSS

cat > "$SITE/sitemap.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://example.test/</loc></url>
  <url><loc>https://example.test/docs/</loc></url>
</urlset>
XML

echo "Sitemap: https://example.test/sitemap.xml" > "$SITE/robots.txt"

echo "check-links.mjs:"

run_case "a site whose internal links all resolve passes" 0 "check-links: clean."
run_case "external links are counted, not checked" 0 "2 external links skipped"

# copy_site name: a fresh copy of the clean site to break one thing in.
copy_site() {
    local dest="$WORK/$1"
    rm -rf "$dest"
    cp -R "$SITE" "$dest"
    echo "$dest"
}

S="$(copy_site missing-page)"
echo '<a href="/nowhere/">Gone</a>' >> "$S/docs/index.html"
run_case "a link to a missing page fails with file and line" 1 "docs/index.html:7: /nowhere/ (no such page or file)" "$S"

S="$(copy_site missing-fragment)"
echo '<a href="/docs/#uninstall">Gone</a>' >> "$S/docs/index.html"
run_case "a link to a missing id fails" 1 'no element with id "uninstall"' "$S"

S="$(copy_site missing-asset)"
rm "$S/assets/img/logo@2x.png"
run_case "a missing srcset candidate fails" 1 "/assets/img/logo@2x.png (no such page or file)" "$S"

S="$(copy_site missing-css-url)"
rm "$S/assets/img/bg.svg"
run_case "a missing CSS url() target fails" 1 "assets/css/main.css:1: ../img/bg.svg" "$S"

S="$(copy_site missing-meta)"
rm "$S/assets/img/logo.png"
run_case "a missing og:image fails" 1 "index.html:4: https://example.test/assets/img/logo.png" "$S"

S="$(copy_site missing-sitemap-entry)"
sed -i.bak 's#/docs/</loc>#/old-docs/</loc>#' "$S/sitemap.xml" && rm "$S/sitemap.xml.bak"
run_case "a sitemap entry for a missing page fails" 1 "sitemap.xml:4: https://example.test/old-docs/" "$S"

S="$(copy_site traversal)"
echo '<a href="/../../etc/passwd">Out</a>' >> "$S/docs/index.html"
echo '<a href="/%2e%2e/%2e%2e/etc/passwd">Out, encoded</a>' >> "$S/docs/index.html"
run_case "a path that climbs out of the site fails" 1 "%2e%2e/%2e%2e/etc/passwd (no such page or file)" "$S"

S="$(copy_site malformed)"
echo '<a href="/bad%zzescape">Bad</a>' >> "$S/docs/index.html"
run_case "an undecodable path fails" 1 "/bad%zzescape (no such page or file)" "$S"

run_case "a missing site directory is a usage error" 2 "run the build first" "$WORK/no-such-site"

if [[ "$failures" -gt 0 ]]; then
    echo "check-links.mjs: $failures failure(s)" >&2
    exit 1
fi
echo "check-links.mjs: all cases passed"
