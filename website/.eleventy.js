// Eleventy config — bocan.app
// We deliberately keep this small: no plugins beyond what Eleventy ships with,
// plus markdown-it for richer markdown rendering.

import markdownIt from "markdown-it";
import markdownItAnchor from "markdown-it-anchor";
import fs from "node:fs";
import path from "node:path";

export default function (eleventyConfig) {
  // Markdown configuration.
  const md = markdownIt({ html: true, linkify: true, typographer: true }).use(
    markdownItAnchor,
    { permalink: markdownItAnchor.permalink.headerLink() }
  );
  eleventyConfig.setLibrary("md", md);

  // Static assets — copied verbatim into _site.
  eleventyConfig.addPassthroughCopy({ "src/assets": "assets" });
  eleventyConfig.addPassthroughCopy({ "static/CNAME": "CNAME" });
  eleventyConfig.addPassthroughCopy({ "static/.well-known": ".well-known" });
  eleventyConfig.addPassthroughCopy({ "static/robots.txt": "robots.txt" });

  // Watch CSS for re-rebuilds.
  eleventyConfig.addWatchTarget("./src/assets/css/");

  // Pull the project CHANGELOG into the site so we don't keep two copies in sync.
  eleventyConfig.addGlobalData("changelog", () => {
    const p = path.resolve("../CHANGELOG.md");
    try {
      return fs.readFileSync(p, "utf8");
    } catch {
      return "_CHANGELOG.md not found at build time._";
    }
  });

  // Filters.
  eleventyConfig.addFilter("year", () => new Date().getFullYear());
  eleventyConfig.addFilter("isoDate", (d) => new Date(d).toISOString());
  eleventyConfig.addFilter("readableDate", (d) =>
    new Date(d).toLocaleDateString("en-GB", {
      day: "numeric",
      month: "long",
      year: "numeric",
    })
  );

  // Markdown filter for inline use in Nunjucks templates.
  eleventyConfig.addFilter("md", (str) => md.render(str || ""));

  return {
    dir: {
      input: "src",
      includes: "_includes",
      data: "_data",
      output: "_site",
    },
    markdownTemplateEngine: "njk",
    htmlTemplateEngine: "njk",
    templateFormats: ["njk", "md", "html"],
  };
}
