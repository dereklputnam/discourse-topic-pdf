# Topic PDF Download Button

A Discourse theme component that adds a "Download PDF" button to topics, generating a clean, print-ready document via the browser's built-in print dialog.

## Features

- **Targeted visibility** — show the button by category, tag, or specific topic IDs
- **First-post or full thread** — export just the original post or include all replies
- **Auto-generated outline** — table of contents built from post headings, with configurable depth (H1 only, H1-H2, H1-H3, or all)
- **Outline checkbox** — end users can toggle the outline on/off; only appears when DiscoTOC is active on the topic
- **Article-style header** — site logo, title with link back to the original topic, tags, and author byline
- **Page numbers** — "Page X of Y" and site title in print margins (Chromium browsers)
- **Print-optimized CSS** — handles Discourse content types including quotes, code blocks, tables, oneboxes, polls, spoilers, emoji, and `[wrap]` blocks

## Settings

| Setting | Description | Default |
|---|---|---|
| `enabled_categories` | Categories where the button appears | *(empty — hidden)* |
| `enabled_tags` | Tags where the button appears | *(empty)* |
| `enabled_topic_ids` | Specific topic IDs to always show the button | *(empty)* |
| `first_post_only` | Only include the original post | `true` |
| `show_post_meta` | Show author and date in the PDF | `true` |
| `show_site_logo` | Show the site logo in the PDF header | `true` |
| `show_tags` | Show topic tags in the PDF header | `true` |
| `show_toc` | Enable the outline feature and checkbox | `true` |
| `toc_max_depth` | Heading depth for the outline | `H1 – H2` |
| `button_style` | Secondary (outline) or primary (filled) | `secondary` |

## Installation

1. In your Discourse admin panel, go to **Admin > Customize > Themes**
2. Click **Install** and enter the repository URL:
   ```
   https://github.com/dereklputnam/discourse-pdf-download
   ```
3. Add the component to your active theme
4. Configure the settings to specify which categories, tags, or topics should show the button

## How It Works

Clicking the button fetches the topic's posts via the Discourse API, builds a styled HTML document, and opens it in a new tab. The browser's print dialog opens automatically, allowing the user to save as PDF or print directly.

## License

MIT
