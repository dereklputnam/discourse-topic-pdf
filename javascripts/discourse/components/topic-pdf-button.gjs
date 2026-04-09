import Component from "@glimmer/component";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import icon from "discourse-common/helpers/d-icon";

// ─── Settings parsers ────────────────────────────────────────────────────────
// list and list_type settings are stored pipe-separated internally.
// topic IDs accept pipe or comma (manual entry).

function parseCategoryIds() {
  return (settings.enabled_categories || "")
    .split("|")
    .map((s) => parseInt(s.trim(), 10))
    .filter((n) => !isNaN(n) && n > 0);
}

function parseTagList() {
  return (settings.enabled_tags || "")
    .split("|")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

function parseTopicIds() {
  return (settings.enabled_topic_ids || "")
    .split(/[,|]/)
    .map((s) => parseInt(s.trim(), 10))
    .filter((n) => !isNaN(n) && n > 0);
}

// ─── HTML helpers ────────────────────────────────────────────────────────────

function escapeHtml(str) {
  if (!str) {
    return "";
  }

  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ─── Content processing ──────────────────────────────────────────────────────
// The cooked HTML from Discourse is already sanitized. We just need to:
//   1. Rewrite relative URLs to absolute (images, links)
//   2. Strip elements that are interactive-only and meaningless in print
//
// [wrap=foo] renders as <div class="d-wrap" data-wrap="foo">…</div>
// These are handled purely via CSS in the print document.

function processCooked(html) {
  if (!html) {
    return "";
  }

  const origin = window.location.origin;

  // Fix relative src (uploads, emoji, etc.)
  html = html.replace(/(\ssrc=")\/(?!\/)/g, `$1${origin}/`);

  // Fix relative href (internal topic/post links)
  html = html.replace(/(\shref=")\/(?!\/)/g, `$1${origin}/`);

  // Remove lightbox overlay metadata divs (they render as blank space)
  html = html.replace(/<div class="meta[^"]*"[^>]*>[\s\S]*?<\/div>/g, "");

  return html;
}

// ─── Table of contents builder ───────────────────────────────────────────────
// Scans an HTML string for <h1>–<h6> elements, injects anchor IDs, and returns
// both the modified HTML and a TOC nav block. Skips headings with no text.

function buildToc(html) {
  const headings = [];
  let counter = 0;

  const processed = html.replace(
    /<h([1-6])(\s[^>]*)?>([^]*?)<\/h\1>/gi,
    (match, level, attrs, inner) => {
      const text = inner.replace(/<[^>]+>/g, "").trim();
      if (!text) {
        return match;
      }
      counter++;
      const id = `pdf-h-${counter}`;
      headings.push({ id, level: parseInt(level, 10), text });
      // Preserve existing attributes; add our id
      const a = attrs || "";
      return `<h${level}${a} id="${id}">${inner}</h${level}>`;
    }
  );

  if (!headings.length) {
    return { html, tocHtml: "" };
  }

  const minLevel = Math.min(...headings.map((h) => h.level));

  const items = headings
    .map((h) => {
      const depth = h.level - minLevel;
      return `<li class="pdf-toc-item pdf-toc-depth-${depth}"><a href="#${h.id}">${escapeHtml(h.text)}</a></li>`;
    })
    .join("\n        ");

  const tocHtml = `
    <nav class="pdf-toc">
      <h1 class="pdf-toc-title">Contents</h1>
      <ol class="pdf-toc-list">
        ${items}
      </ol>
    </nav>`;

  return { html: processed, tocHtml };
}

// ─── PDF document builder ────────────────────────────────────────────────────

function buildPrintHtml(topic, posts, logoUrl, tocEnabled) {
  const origin = window.location.origin;
  const topicUrl = `${origin}/t/${encodeURIComponent(topic.slug || topic.id)}/${topic.id}`;

  // Grab site title from og:site_name or fall back to the hostname
  const siteTitle =
    document.querySelector("meta[property='og:site_name']")?.getAttribute("content") ||
    document.title.split(" - ").slice(-1)[0]?.trim() ||
    window.location.hostname;

  // topic.tags can be an array of strings or tag objects with a .name property
  const tagNames = (topic.tags || []).map((t) =>
    typeof t === "string" ? t : t?.name || ""
  ).filter(Boolean);

  const tagsHtml = settings.show_tags && tagNames.length
    ? `<div class="pdf-tags">${tagNames
        .map((t) => `<span class="pdf-tag">${escapeHtml(t)}</span>`)
        .join(" ")}</div>`
    : "";

  // OP byline goes in the header (above the rule) for an article feel
  const firstPost = posts[0];
  const opBylineHtml = settings.show_post_meta && firstPost
    ? (() => {
        const date = new Date(firstPost.created_at).toLocaleDateString(undefined, {
          year: "numeric",
          month: "long",
          day: "numeric",
        });
        return `<div class="pdf-byline">
          <strong class="pdf-author">${escapeHtml(firstPost.username)}</strong>
          <span class="pdf-date">${escapeHtml(date)}</span>
        </div>`;
      })()
    : "";

  let postsHtml = posts
    .map((post, idx) => {
      const cooked = processCooked(post.cooked || "");

      // OP meta is rendered in the header; only show meta for replies
      const metaHtml = settings.show_post_meta && idx > 0
        ? (() => {
            const date = new Date(post.created_at).toLocaleDateString(undefined, {
              year: "numeric",
              month: "long",
              day: "numeric",
            });
            return `<div class="pdf-post-meta">
              <strong class="pdf-author">${escapeHtml(post.username)}</strong>
              <span class="pdf-date">${escapeHtml(date)}</span>
              <span class="pdf-post-num">Reply #${post.post_number}</span>
            </div>`;
          })()
        : "";

      return `
        <div class="pdf-post${idx === 0 ? " pdf-op" : " pdf-reply"}">
          ${metaHtml}
          <div class="pdf-cooked">${cooked}</div>
        </div>
      `;
    })
    .join('<div class="pdf-separator" role="separator"></div>');

  // Build TOC from headings found in the post content
  let tocHtml = "";
  if (tocEnabled) {
    const toc = buildToc(postsHtml);
    postsHtml = toc.html;
    tocHtml = toc.tocHtml;
  }

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(topic.title)}</title>
  <style>${getPdfCss(siteTitle)}</style>
</head>
<body>
  <div class="pdf-wrap">

    <header class="pdf-header">
      ${logoUrl
        ? `<img class="pdf-logo" src="${escapeHtml(logoUrl)}" alt="${escapeHtml(siteTitle)}">`
        : `<div class="pdf-source">${escapeHtml(siteTitle)}</div>`
      }
      <h1 class="pdf-title">
        ${escapeHtml(topic.title)}<a class="pdf-title-link" href="${escapeHtml(topicUrl)}" title="Link to original document"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg></a>
      </h1>
      ${tagsHtml}
      ${opBylineHtml}
    </header>

    ${tocHtml}

    <main class="pdf-body">
      ${postsHtml}
    </main>

    <footer class="pdf-footer">
      <span>${escapeHtml(siteTitle)}</span>
      <span>Downloaded ${new Date().toLocaleDateString()}</span>
    </footer>

  </div>
  <script>
    window.addEventListener("load", function () {
      // Inject TOC page numbers (best-effort — assumes default print scale)
      var tocItems = document.querySelectorAll('.pdf-toc-item');
      if (tocItems.length) {
        // Temporarily apply print-like layout for accurate measurement
        var wrap = document.querySelector('.pdf-wrap');
        var origFS = document.body.style.fontSize;
        var origMW = wrap.style.maxWidth;
        var origPD = wrap.style.padding;
        document.body.style.fontSize = '11pt';
        wrap.style.maxWidth = '100%';
        wrap.style.padding = '0';
        void document.body.offsetHeight; // force reflow

        // Content area: letter 9.5in or A4 10.19in at 96px/in
        var pageH = 9.5 * 96; // 912px

        tocItems.forEach(function (item) {
          var link = item.querySelector('a');
          var href = link && link.getAttribute('href');
          if (!href) return;
          var target = document.querySelector(href);
          if (!target) return;

          var pageNum = Math.floor(target.offsetTop / pageH) + 1;

          var leader = document.createElement('span');
          leader.className = 'pdf-toc-leader';
          leader.setAttribute('aria-hidden', 'true');
          item.appendChild(leader);

          var span = document.createElement('span');
          span.className = 'pdf-toc-page';
          span.textContent = pageNum;
          item.appendChild(span);
        });

        // Restore screen styles
        document.body.style.fontSize = origFS;
        wrap.style.maxWidth = origMW;
        wrap.style.padding = origPD;
      }

      setTimeout(function () { window.print(); }, 700);
    });
  </script>
</body>
</html>`;
}

// ─── Print CSS ───────────────────────────────────────────────────────────────
// Applied inside the popup window. Handles Discourse's cooked HTML conventions:
//   - aside.quote      → Discourse blockquotes
//   - .d-wrap          → [wrap=…] BBCode
//   - aside.onebox     → link previews
//   - details/summary  → spoilers
//   - .poll            → poll embeds
//   - img.emoji        → inline emoji images

function getPdfCss(siteTitle) {
  return `
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                   Helvetica, Arial, sans-serif;
      font-size: 13pt;
      line-height: 1.65;
      color: #1a1a1a;
      background: #fff;
    }

    .pdf-wrap {
      max-width: 760px;
      margin: 0 auto;
      padding: 36px 40px;
    }

    /* ── Header ── */
    .pdf-header {
      padding-bottom: 18px;
      margin-bottom: 28px;
      border-bottom: 2px solid #ddd;
    }

    .pdf-logo {
      display: block;
      max-height: 48px;
      max-width: 200px;
      width: auto;
      height: auto;
      object-fit: contain;
      margin-bottom: 14px;
    }

    .pdf-source {
      font-size: 9pt;
      text-transform: uppercase;
      letter-spacing: .07em;
      color: #888;
      margin-bottom: 6px;
    }

    .pdf-title {
      font-size: 20pt;
      font-weight: 700;
      line-height: 1.25;
      color: #111;
      margin-bottom: 10px;
    }

    /* Chain-link icon inline after the title */
    .pdf-title-link {
      display: inline-flex;
      align-items: center;
      margin-left: 6px;
      vertical-align: middle;
      color: #aaa;
      text-decoration: none;
    }

    .pdf-title-link:hover { color: #0076d6; }

    .pdf-title-link svg {
      width: 16px;
      height: 16px;
      fill: none;
      stroke: #aaa;
      stroke-width: 2;
      stroke-linecap: round;
      stroke-linejoin: round;
    }

    .pdf-tags { margin-bottom: 8px; }

    .pdf-tag {
      display: inline-block;
      background: #f0f0f0;
      border-radius: 3px;
      padding: 1px 7px;
      font-size: 9pt;
      color: #555;
      margin-right: 4px;
    }

    /* ── OP byline (in header, above rule) ── */
    .pdf-byline {
      display: flex;
      gap: 10px;
      align-items: baseline;
      font-size: 9.5pt;
      color: #777;
      margin-top: 4px;
    }

    .pdf-byline .pdf-author { color: #333; font-weight: 600; }

    /* ── Table of contents ── */
    .pdf-toc {
      margin-bottom: 24px;
      padding-bottom: 20px;
      border-bottom: 1px solid #e4e4e4;
    }

    .pdf-toc-title {
      font-size: 16pt;
      font-weight: 700;
      line-height: 1.3;
      color: #111;
      margin-bottom: 10px;
    }

    .pdf-toc-list {
      list-style: none;
      margin: 0;
      padding: 0;
    }

    .pdf-toc-item {
      display: flex;
      align-items: baseline;
      margin: 3px 0;
      font-size: 10.5pt;
      line-height: 1.6;
    }

    .pdf-toc-item a {
      color: #0076d6;
      text-decoration: none;
      white-space: nowrap;
    }

    .pdf-toc-item a:hover { text-decoration: underline; }

    .pdf-toc-leader {
      flex: 1;
      border-bottom: 1px dotted #ccc;
      margin: 0 6px;
      min-width: 2em;
      position: relative;
      bottom: 3px;
    }

    .pdf-toc-page {
      white-space: nowrap;
      color: #555;
      font-size: 10pt;
    }

    .pdf-toc-depth-1 { margin-left: 1.2em; }
    .pdf-toc-depth-2 { margin-left: 2.4em; }
    .pdf-toc-depth-3 { margin-left: 3.6em; }
    .pdf-toc-depth-4 { margin-left: 4.8em; }

    /* ── Post layout ── */
    .pdf-post-meta {
      display: flex;
      gap: 14px;
      align-items: baseline;
      margin-bottom: 8px;
      font-size: 9.5pt;
      color: #777;
    }

    .pdf-author { color: #333; font-weight: 600; }
    .pdf-post-num { font-size: 8.5pt; }

    .pdf-separator {
      border-top: 1px solid #e4e4e4;
      margin: 22px 0;
    }

    /* ── Cooked content ── */
    .pdf-cooked p { margin: 0 0 .75em; }
    .pdf-cooked p:last-child { margin-bottom: 0; }

    .pdf-cooked h1,
    .pdf-cooked h2,
    .pdf-cooked h3,
    .pdf-cooked h4,
    .pdf-cooked h5,
    .pdf-cooked h6 {
      margin: 1em 0 .4em;
      font-weight: 700;
      line-height: 1.3;
      page-break-after: avoid;
    }

    .pdf-cooked h1 { font-size: 16pt; }
    .pdf-cooked h2 { font-size: 14pt; }
    .pdf-cooked h3 { font-size: 12pt; }
    .pdf-cooked h4 { font-size: 11pt; }

    .pdf-cooked ul,
    .pdf-cooked ol { margin: .5em 0 .75em 1.4em; }

    .pdf-cooked li { margin-bottom: .25em; }

    .pdf-cooked pre {
      background: #f5f5f5;
      border: 1px solid #ddd;
      border-radius: 4px;
      padding: 10px 14px;
      font-size: 10pt;
      white-space: pre-wrap;
      word-break: break-word;
      page-break-inside: avoid;
    }

    .pdf-cooked code {
      background: #f0f0f0;
      border-radius: 3px;
      padding: 0 4px;
      font-size: 10pt;
    }

    .pdf-cooked pre code { background: none; padding: 0; }

    .pdf-cooked blockquote {
      border-left: 3px solid #ccc;
      margin: .75em 0;
      padding: .5em 1em;
      background: #fafafa;
      color: #555;
    }

    .pdf-cooked img {
      max-width: 100%;
      height: auto;
      display: block;
      margin: .5em 0;
      page-break-inside: avoid;
    }

    /* Inline emoji — keep them inline and small */
    .pdf-cooked img.emoji {
      display: inline;
      width: 18px;
      height: 18px;
      margin: 0 1px;
      vertical-align: middle;
    }

    .pdf-cooked table {
      border-collapse: collapse;
      width: 100%;
      margin: .75em 0;
      font-size: 11pt;
    }

    .pdf-cooked th,
    .pdf-cooked td {
      border: 1px solid #ddd;
      padding: 5px 9px;
      text-align: left;
    }

    .pdf-cooked th { background: #f4f4f4; font-weight: 600; }

    .pdf-cooked a {
      color: #0076d6;
      word-break: break-word;
    }

    .pdf-cooked a.mention { color: #5c7cfa; text-decoration: none; }

    /* Discourse quote blocks — aside.quote */
    .pdf-cooked aside.quote {
      border-left: 3px solid #bbb;
      background: #f8f8f8;
      margin: .75em 0;
      padding: .5em 1em;
      page-break-inside: avoid;
    }

    .pdf-cooked aside.quote .title {
      font-size: 9pt;
      color: #888;
      font-weight: 600;
      margin-bottom: 4px;
    }

    /* [wrap=…] → .d-wrap */
    .pdf-cooked .d-wrap {
      border: 1px solid #e0e0e0;
      border-radius: 4px;
      padding: 10px 14px;
      margin: .75em 0;
    }

    /* Onebox link previews */
    .pdf-cooked aside.onebox {
      border: 1px solid #e0e0e0;
      border-radius: 4px;
      padding: 10px 14px;
      margin: .75em 0;
      font-size: 11pt;
      page-break-inside: avoid;
    }

    /* Details/spoiler */
    .pdf-cooked details {
      border: 1px solid #ddd;
      border-radius: 4px;
      padding: 8px 12px;
      margin: .5em 0;
    }

    .pdf-cooked details[open] > summary { margin-bottom: 6px; }

    /* Polls */
    .pdf-cooked .poll {
      border: 1px solid #ddd;
      border-radius: 4px;
      padding: 10px 14px;
      margin: .75em 0;
      font-size: 11pt;
    }

    .pdf-cooked .poll .poll-info {
      font-size: 9pt;
      color: #888;
      margin-top: 6px;
    }

    /* Strip UI-only noise */
    .pdf-cooked .lightbox-wrapper .meta,
    .pdf-cooked .quote-controls,
    .pdf-cooked button,
    .pdf-cooked .btn,
    .pdf-cooked .expand-help,
    .pdf-cooked [data-poll-status] .results { display: none !important; }

    /* ── Footer ── */
    .pdf-footer {
      margin-top: 28px;
      padding-top: 12px;
      border-top: 1px solid #e0e0e0;
      display: flex;
      justify-content: space-between;
      font-size: 8.5pt;
      color: #bbb;
    }

    /* ── @media print ── */
    @page {
      margin: 0.75in;

      @bottom-left {
        content: "${escapeHtml(siteTitle)}";
        font-size: 8pt;
        color: #bbb;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                     Helvetica, Arial, sans-serif;
      }

      @bottom-right {
        content: "Page " counter(page) " of " counter(pages);
        font-size: 8pt;
        color: #bbb;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
                     Helvetica, Arial, sans-serif;
      }
    }

    @media print {
      body { font-size: 11pt; }
      .pdf-wrap { padding: 0; max-width: 100%; }

      /* Body footer hidden in print — info is in the page margins */
      .pdf-footer { display: none; }

      /* Suppress "URL (href)" that some browsers append to links */
      a::after { content: "" !important; }

      pre,
      blockquote,
      aside,
      .d-wrap,
      .poll { page-break-inside: avoid; }
    }
  `;
}

// ─── Post fetcher ─────────────────────────────────────────────────────────────
// Fetches the first page of posts from /t/{id}.json. If the topic has more
// posts than fit on the first page, fetches the remaining ones in chunks of 20
// via /t/{id}/posts.json?post_ids[]=…
//
// NOTE: When first_post_only is true, a single API call is enough.

async function fetchPosts(topic) {
  const firstPage = await ajax(`/t/${topic.id}.json`);
  const { posts, stream } = firstPage.post_stream;

  if (settings.first_post_only) {
    return posts.slice(0, 1);
  }

  const allIds = stream || [];
  const fetchedIds = new Set(posts.map((p) => p.id));
  const remainingIds = allIds.filter((id) => !fetchedIds.has(id));

  if (!remainingIds.length) {
    return posts;
  }

  let allPosts = [...posts];
  const CHUNK = 20;

  for (let i = 0; i < remainingIds.length; i += CHUNK) {
    const chunk = remainingIds.slice(i, i + CHUNK);
    const data = await ajax(`/t/${topic.id}/posts.json`, {
      data: { post_ids: chunk },
    });
    allPosts = allPosts.concat(data.post_stream.posts);
  }

  // Re-sort by post_number in case pagination returned them out of order
  allPosts.sort((a, b) => a.post_number - b.post_number);
  return allPosts;
}

// ─── Component ────────────────────────────────────────────────────────────────

export default class TopicPdfButton extends Component {
  @service siteSettings;
  @tracked isLoading = false;
  @tracked errorMsg = null;
  @tracked includeToc = settings.show_toc;

  get logoUrl() {
    if (!settings.show_site_logo) {
      return null;
    }
    // siteSettings.logo is the admin-configured path (e.g. /uploads/…).
    // It never changes with scroll state — unlike the DOM header element.
    const path = this.siteSettings?.logo;
    if (!path) {
      return null;
    }
    if (path.startsWith("//")) {
      return `${window.location.protocol}${path}`;
    }
    return path.startsWith("http") ? path : `${window.location.origin}${path}`;
  }

  // topic-navigation passes model; above-topic-footer-buttons passes topic
  get topic() {
    return (
      this.args.outletArgs?.model ||
      this.args.outletArgs?.topic
    );
  }

  get shouldShow() {
    const topic = this.topic;
    if (!topic) {
      return false;
    }

    const categoryIds = parseCategoryIds();
    const tags = parseTagList();
    const topicIds = parseTopicIds();

    // Nothing configured → hidden everywhere
    if (!categoryIds.length && !tags.length && !topicIds.length) {
      return false;
    }

    if (topicIds.length && topicIds.includes(topic.id)) {
      return true;
    }

    if (categoryIds.length && categoryIds.includes(topic.category_id)) {
      return true;
    }

    const topicTags = (topic.tags || []).map((t) =>
      (typeof t === "string" ? t : t?.name || "").toLowerCase()
    );
    if (tags.length && tags.some((t) => topicTags.includes(t))) {
      return true;
    }

    return false;
  }

  // Detect DiscoTOC after it has rendered. The modifier fires on insert and
  // re-runs when its argument (topic) changes, handling SPA navigation.
  @tracked tocDetected = false;

  detectToc = modifier((element, [topic]) => {
    this.tocDetected = false;
    if (!settings.show_toc) {
      return;
    }
    const timer = setTimeout(() => {
      this.tocDetected = !!document.querySelector(".d-toc-item");
    }, 800);
    return () => clearTimeout(timer);
  });

  @action
  toggleToc(event) {
    this.includeToc = event.target.checked;
  }

  @action
  async downloadPdf() {
    if (this.isLoading) {
      return;
    }

    this.isLoading = true;
    this.errorMsg = null;

    try {
      const posts = await fetchPosts(this.topic);
      const html = buildPrintHtml(this.topic, posts, this.logoUrl, this.includeToc);

      const win = window.open("", "_blank");

      if (!win) {
        // Popup was blocked — alert is the only reliable fallback
        // eslint-disable-next-line no-alert
        alert("Please allow popups for this site to download PDFs.");
        return;
      }

      win.document.open();
      win.document.write(html);
      win.document.close();

      // Trigger print from the opener — more reliable than the inline
      // script inside the popup, which some browsers block.
      setTimeout(() => {
        try {
          win.print();
        } catch (e) {
          // Silently ignore if the popup was closed before print fired
        }
      }, 800);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error("[topic-pdf-download]", err);
      this.errorMsg = "Could not generate PDF. Please try again.";
    } finally {
      this.isLoading = false;
    }
  }

  get buttonClass() {
    const style =
      settings.button_style === "primary" ? "btn-primary" : "btn-default";
    return `btn ${style} topic-pdf-btn`;
  }

  get buttonLabel() {
    return this.isLoading ? "Preparing…" : "Download PDF";
  }

  <template>
    {{#if this.shouldShow}}
      <div class="topic-pdf-btn-wrap" {{this.detectToc this.topic}}>
        <button
          type="button"
          class={{this.buttonClass}}
          disabled={{this.isLoading}}
          title="Download PDF"
          {{on "click" this.downloadPdf}}
        >
          {{icon "download"}}
          <span>{{this.buttonLabel}}</span>
        </button>
        {{#if this.errorMsg}}
          <span class="topic-pdf-error">{{this.errorMsg}}</span>
        {{/if}}
        {{#if this.tocDetected}}
          <label class="topic-pdf-toc-toggle">
            <input
              type="checkbox"
              checked={{this.includeToc}}
              {{on "change" this.toggleToc}}
            />
            Include outline
          </label>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
