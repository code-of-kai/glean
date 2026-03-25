# Changelog

## 0.1.0 — 2026-03-25

Initial release.

- Single-page scraping with Markdown output
- Concurrent multi-page fetching (up to 20 simultaneous)
- Crawl mode with smart link filtering
  - Content-area link extraction
  - Junk path blocklist (~40 common non-content paths)
  - Path affinity scoring
  - Explicit `--pattern` override
- Markdown formatting: headings, bold, italic, lists, code blocks, blockquotes, tables
- Claude Code skill integration (SKILL.md)
