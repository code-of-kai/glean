---
name: glean
description: Scrapes web pages to clean Markdown. Fast, concurrent, text-only.
---

# Glean

Fast, text-only web scraper written in Elixir. Extracts the main content from URLs and returns clean Markdown. Can crawl an entire site's subpages concurrently — 20 pages in ~2 seconds.

## When to use

Use this skill whenever the user asks to:
- Scrape, fetch, or read a web page
- Extract text/content from a URL
- Get the article or main content from a webpage
- Grab all subpages from a site
- Summarize or analyze a webpage (scrape first, then process)

## How it works

Pure Elixir using `Req` (HTTP) and `Floki` (HTML parsing) via `Mix.install`:
1. Fetches pages concurrently (up to 20 at once) using BEAM lightweight processes
2. Finds the main content container (article, main, [role=main], etc.) and strips nav, sidebars, footers, ads
3. Converts to clean Markdown preserving headings, bold, italic, lists, code blocks, blockquotes

## Usage

```bash
elixir ~/.claude/skills/glean/glean.exs [OPTIONS] URL [URL...]
```

### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--include-links` | `-l` | Preserve hyperlinks as `[text](url)` |
| `--include-tables` | `-t` | Include table content |
| `--crawl` | `-c` | Discover same-domain content links and scrape them too |
| `--pattern PATTERN` | `-p` | Only crawl links whose path contains PATTERN |
| `--max-pages N` | | Max pages in crawl mode (default: 50) |

### Examples

Single page:
```bash
elixir ~/.claude/skills/glean/glean.exs https://example.com/article
```

Multiple pages concurrently:
```bash
elixir ~/.claude/skills/glean/glean.exs https://example.com/page1 https://example.com/page2
```

Crawl with smart filtering (auto mode):
```bash
elixir ~/.claude/skills/glean/glean.exs --crawl https://example.com/blog
```

Crawl with explicit pattern:
```bash
elixir ~/.claude/skills/glean/glean.exs --crawl --pattern "/blog/" https://example.com/blog
```

### Output format

- Single URL: Markdown text to stdout
- Multiple URLs: Each result separated by `--- <url> ---` headers
- Crawl stats go to stderr (total links found, content-area links, after filtering)
- Errors go to stderr; the script continues with remaining URLs

## Smart Crawl Filtering

When `--crawl` is used, the scraper has two modes:

### Mode 1: Auto (default)

The scraper automatically filters links to find real content pages:

1. **Content-area only**: Prefers links found inside `<article>`, `<main>`, `[role=main]`, etc. — not from nav/header/footer/sidebar
2. **Junk blocklist**: Skips ~40 common non-content paths (/contact, /about, /login, /privacy, /cart, /search, /subscribe, etc.)
3. **Path affinity**: If the seed URL has a meaningful path prefix (e.g. `/blog/`), prefers links sharing that prefix
4. **File type filter**: Skips non-page URLs (.pdf, .png, .css, .js, etc.)

If the content area yields zero links (e.g. the page has no semantic HTML), it falls back to all same-domain links with the junk filter still applied.

### Mode 2: Assisted (Claude-driven)

If auto mode produces results that look wrong (too few links, too heterogeneous, clearly wrong pages), Claude should:

1. Report what was found to the user
2. Ask for either:
   - **A sample link**: "Give me one example of the kind of page you want" — then Claude infers the pattern and re-runs with `--pattern`
   - **A screenshot**: Claude identifies the right section of the page visually and determines the CSS selector or URL pattern
3. Re-run with `--pattern` to target exactly the right links

## Performance

- **~1.5s** for a single page (including BEAM startup)
- **~2s** for 10 pages concurrently (crawl mode)
- 20 concurrent connections, no browser, no JS rendering
- First run compiles deps (~7s); subsequent runs use the cache

## Limitations

- **JS-rendered pages**: Cannot scrape SPAs or pages that require JavaScript execution
- **Paywalled content**: Cannot bypass login walls
- **Images/media**: Intentionally excluded — text only

## Instructions for Claude

1. Run the scrape command with the URL(s) the user provided
2. If the user says "grab all pages" or "scrape the whole site", use `--crawl`
3. Default to NOT including links (cleaner output). Only add `--include-links` if links are specifically needed
4. If extraction returns empty content, the page likely requires JavaScript — tell the user
5. The output is clean Markdown — use it directly in your response or save to a file
6. For large crawls, use `--max-pages` to limit scope
7. **After a crawl, review the stderr stats.** If `content_area_count` is 0 and the filtered results look off, switch to assisted mode: show the user what you found and ask for a sample link or screenshot to calibrate
8. If the user provides a sample link, extract its path pattern and re-run with `--pattern`
