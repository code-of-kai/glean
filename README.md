# Glean

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill for fast web scraping. Extracts main page content as clean Markdown — no sidebars, no ads, no images, just the text.

Built as a single Elixir script. Uses BEAM lightweight processes to fetch up to 20 pages concurrently.

## Install

**Prerequisite:** [Elixir](https://elixir-lang.org/install.html) 1.15+

```bash
mkdir -p ~/.claude/skills/glean
curl -fsSL https://raw.githubusercontent.com/code-of-kai/glean/main/glean.exs -o ~/.claude/skills/glean/glean.exs
curl -fsSL https://raw.githubusercontent.com/code-of-kai/glean/main/SKILL.md -o ~/.claude/skills/glean/SKILL.md
```

That's it. Use `/glean` in Claude Code, or just ask Claude to scrape a page — it triggers automatically.

Dependencies (`Req` and `Floki`) are fetched and cached by Elixir on first run. No `mix deps.get`, no project setup.

## What it does

- Extracts the **main content** from web pages (articles, blog posts, docs)
- Strips navigation, sidebars, footers, ads, and images automatically
- Outputs clean **Markdown** preserving headings, bold, italic, lists, code blocks, and blockquotes
- Crawls entire sites concurrently with **smart link filtering** — skips junk pages like /contact, /about, /login
- Fetches up to **20 pages simultaneously** using BEAM processes

## Standalone usage

The script also works outside Claude Code as a regular CLI tool:

```bash
# Single page
elixir glean.exs https://example.com/article

# Multiple pages (fetched concurrently)
elixir glean.exs https://example.com/page1 https://example.com/page2

# Crawl a site — discovers content links and scrapes them all
elixir glean.exs --crawl https://example.com/blog

# Crawl with a pattern filter
elixir glean.exs --crawl --pattern "/essays/" https://paulgraham.com/articles.html

# Save to file
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

## Output

- **Single URL**: Markdown to stdout
- **Multiple URLs**: Each result separated by `--- <url> ---` headers
- **Crawl stats**: Printed to stderr
- **Errors**: Printed to stderr; continues with remaining URLs

## Performance

| Scenario | Time |
|----------|------|
| Single page (including BEAM startup) | ~1.5s |
| 10 pages concurrently (crawl mode) | ~2s |
| First run (dependency compilation) | ~7s |

## How it works

A single Elixir script (`glean.exs`) using `Mix.install` for zero-setup dependency management:

- **[Req](https://hex.pm/packages/req)** — HTTP client
- **[Floki](https://hex.pm/packages/floki)** — HTML parser
- **Task.async_stream** — BEAM's built-in concurrency

The extraction pipeline: parse HTML, find the main content container, strip unwanted elements (nav, footer, scripts, etc.), walk the DOM tree, convert to Markdown.

## Limitations

- **JS-rendered pages**: Cannot scrape SPAs or pages requiring JavaScript (React/Vue without SSR)
- **Paywalled content**: Cannot bypass login walls
- **Images/media**: Intentionally excluded — text only by design

## License

MIT
