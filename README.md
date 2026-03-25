# Glean

Fast, text-only web scraper that extracts main content as clean Markdown. Built in Elixir for concurrent page fetching via BEAM lightweight processes.

**Single file. No project setup. Just run it.**

## What it does

- Extracts the **main content** from web pages (articles, blog posts, docs)
- Strips navigation, sidebars, footers, ads, and images automatically
- Outputs clean **Markdown** with headings, bold, italic, lists, code blocks, and blockquotes preserved
- Crawls entire sites concurrently with **smart link filtering** — skips junk pages like /contact, /about, /login
- Fetches up to **20 pages simultaneously** using BEAM processes

## Requirements

- [Elixir](https://elixir-lang.org/install.html) 1.15+ (uses `Mix.install` for zero-setup dependencies)

That's it. No `mix deps.get`, no project setup. Dependencies (`Req` and `Floki`) are fetched and cached automatically on first run.

## Usage

### Single page

```bash
elixir glean.exs https://example.com/article
```

### Multiple pages (fetched concurrently)

```bash
elixir glean.exs https://example.com/page1 https://example.com/page2 https://example.com/page3
```

### Crawl a site

Discovers content links on the page and scrapes them all concurrently:

```bash
elixir glean.exs --crawl https://example.com/blog
```

### Crawl with a pattern filter

Only follow links whose path contains a specific string:

```bash
elixir glean.exs --crawl --pattern "/essays/" https://paulgraham.com/articles.html
```

### Save output to a file

```bash
elixir glean.exs https://example.com/article > article.md
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--include-links` | `-l` | Preserve hyperlinks as `[text](url)` |
| `--include-tables` | `-t` | Include table content as Markdown tables |
| `--crawl` | `-c` | Discover same-domain content links and scrape them too |
| `--pattern PATTERN` | `-p` | Only crawl links whose path contains PATTERN |
| `--max-pages N` | | Max pages to scrape in crawl mode (default: 50) |
| `--help` | `-h` | Show help |

## Smart Crawl Filtering

When `--crawl` is used, Glean doesn't just grab every link on the page. It filters intelligently:

1. **Content-area only** — Prefers links found inside `<article>`, `<main>`, `[role=main]`, etc., ignoring nav/header/footer/sidebar links
2. **Junk blocklist** — Skips ~40 common non-content paths (`/contact`, `/about`, `/login`, `/privacy`, `/cart`, `/search`, `/subscribe`, etc.)
3. **Path affinity** — If the seed URL has a meaningful path prefix (e.g. `/blog/`), prefers links sharing that prefix
4. **File type filter** — Skips non-page URLs (`.pdf`, `.png`, `.css`, `.js`, etc.)

If the content area yields zero links (e.g. the page has no semantic HTML), it falls back to all same-domain links with the junk filter still applied.

## Output format

- **Single URL**: Markdown text printed to stdout
- **Multiple URLs**: Each result separated by `--- <url> ---` headers
- **Crawl stats**: Printed to stderr (total links, content-area links, after filtering)
- **Errors**: Printed to stderr; the script continues with remaining URLs

## Performance

| Scenario | Time |
|----------|------|
| Single page (including BEAM startup) | ~1.5s |
| 10 pages concurrently (crawl mode) | ~2s |
| First run (dependency compilation) | ~7s |

## How it works

Glean is a single Elixir script (`glean.exs`) that uses `Mix.install` for zero-setup dependency management:

- **[Req](https://hex.pm/packages/req)** — HTTP client for fetching pages
- **[Floki](https://hex.pm/packages/floki)** — HTML parser for content extraction and link discovery
- **Task.async_stream** — BEAM's built-in concurrency for parallel page fetching

The extraction pipeline:

1. Parse HTML with Floki
2. Find the main content container (`<article>`, `<main>`, `[role=main]`, common CSS classes)
3. Strip unwanted elements (nav, footer, header, aside, scripts, styles, forms)
4. Walk the DOM tree and convert to Markdown, preserving semantic formatting

## Limitations

- **JavaScript-rendered pages**: Cannot scrape SPAs or pages that require JS execution (React/Vue apps without SSR). For these, use a browser-based tool.
- **Paywalled content**: Cannot bypass login walls or paywalls.
- **Images/media**: Intentionally excluded — this is a text-only tool by design.

## Use as a Claude Code skill

Glean was built as a [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill. To install it:

```bash
# Copy to your Claude Code skills directory
mkdir -p ~/.claude/skills/glean
cp glean.exs ~/.claude/skills/glean/
cp SKILL.md ~/.claude/skills/glean/
```

Then Claude can use it via the `/glean` slash command, or it will be triggered automatically when you ask Claude to scrape a web page.

## License

MIT
