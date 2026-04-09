import Component from "@glimmer/component";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
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

// ─── PDF document builder ────────────────────────────────────────────────────

function buildPrintHtml(topic, posts) {
  const origin = window.location.origin;
  const topicUrl = `${origin}/t/${encodeURIComponent(topic.slug || topic.id)}/${topic.id}`;

  // Grab site title from og:site_name or fall back to the hostname
  const siteTitle =
    document.querySelector("meta[property='og:site_name']")?.getAttribute("content") ||
    document.title.split(" - ").slice(-1)[0]?.trim() ||
    window.location.hostname;

  const tagsHtml =
    topic.tags && topic.tags.length
      ? `<div class="pdf-tags">${topic.tags
          .map((t) => `<span class="pdf-tag">${escapeHtml(t)}</span>`)
          .join(" ")}</div>`
      : "";

  const postsHtml = posts
    .map((post, idx) => {
      const cooked = processCooked(post.cooked || "");

      const date = new Date(post.created_at).toLocaleDateString(undefined, {
        year: "numeric",
        month: "long",
        day: "numeric",
      });

      const metaHtml = settings.show_post_meta
        ? `<div class="pdf-post-meta">
            <strong class="pdf-author">${escapeHtml(post.username)}</strong>
            <span class="pdf-date">${escapeHtml(date)}</span>
            ${idx > 0 ? `<span class="pdf-post-num">Reply #${post.post_number}</span>` : ""}
           </div>`
        : "";

      return `
        <div class="pdf-post${idx === 0 ? " pdf-op" : " pdf-reply"}">
          ${metaHtml}
          <div class="pdf-cooked">${cooked}</div>
        </div>
      `;
    })
    .join('<div class="pdf-separator" role="separator"></div>');

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(topic.title)}</title>
  <style>${getPdfCss()}</style>
</head>
<body>
  <div class="pdf-wrap">

    <header class="pdf-header">
      <div class="pdf-source">${escapeHtml(siteTitle)}</div>
      <h1 class="pdf-title">${escapeHtml(topic.title)}</h1>
      ${tagsHtml}
      <a class="pdf-url" href="${escapeHtml(topicUrl)}">${escapeHtml(topicUrl)}</a>
    </header>

    <main class="pdf-body">
      ${postsHtml}
    </main>

    <footer class="pdf-footer">
      <span>${escapeHtml(siteTitle)}</span>
      <span>Downloaded ${new Date().toLocaleDateString()}</span>
    </footer>

  </div>
  <script>
    // Wait for images to fully load before opening print dialog
    window.addEventListener("load", function () {
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

function getPdfCss() {
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

    .pdf-url {
      font-size: 8.5pt;
      color: #aaa;
      word-break: break-all;
      text-decoration: none;
    }

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
    @media print {
      body { font-size: 11pt; }
      .pdf-wrap { padding: 0; max-width: 100%; }

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
  @tracked isLoading = false;
  @tracked errorMsg = null;

  // Post-level outlets (e.g. post-before-cooked) pass `post`.
  // Topic-level outlets (e.g. topic-above-posts) pass `model` or `topic`.
  get post() {
    return this.args.outletArgs?.post;
  }

  get topic() {
    if (this.post?.topic) return this.post.topic;
    return this.args.outletArgs?.model || this.args.outletArgs?.topic;
  }

  get shouldShow() {
    // Post-level outlet: only render on the first post, not every reply
    const post = this.post;
    if (post && post.post_number !== 1) {
      return false;
    }

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

    const topicTags = (topic.tags || []).map((t) => t.toLowerCase());
    if (tags.length && tags.some((t) => topicTags.includes(t))) {
      return true;
    }

    return false;
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
      const html = buildPrintHtml(this.topic, posts);

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
      <div class="topic-pdf-btn-wrap">
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
      </div>
    {{/if}}
  </template>
}
