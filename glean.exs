#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.5"},
  {:floki, "~> 0.37"}
])

defmodule Glean do
  @moduledoc """
  Glean — fast web scraper that extracts main text content as clean Markdown.

  Fetches web pages concurrently using BEAM lightweight processes and converts
  the main content to Markdown, stripping navigation, sidebars, ads, and images.

  ## Public API

    * `scrape/2` — fetch a URL and return its main content as Markdown
    * `discover_links/2` — find content links on a page with smart filtering

  ## Examples

      # Single page
      {url, markdown} = Glean.scrape("https://example.com/article")

      # With options
      {url, markdown} = Glean.scrape("https://example.com/article", include_links: true)

      # Discover content links for crawling
      {links, stats} = Glean.discover_links("https://example.com/blog")

      # Discover with explicit pattern
      {links, stats} = Glean.discover_links("https://example.com", pattern: "/blog/")
  """

  @typedoc "Options for scraping and link discovery."
  @type scrape_opt :: {:include_links, boolean()} | {:include_tables, boolean()}

  @typedoc "Options for link discovery."
  @type discover_opt :: {:pattern, String.t()} | scrape_opt

  @typedoc "Stats returned from link discovery."
  @type discover_stats :: %{
          content_area_count: non_neg_integer(),
          total_count: non_neg_integer(),
          after_filter: non_neg_integer(),
          pattern_used: String.t() | nil
        }

  @block_tags ~w(article main section div p h1 h2 h3 h4 h5 h6 blockquote ul ol li pre table thead tbody tr td th figure figcaption details summary dl dt dd hr br)
  @strip_tags ~w(nav footer header aside form noscript script style svg iframe object embed applet link meta head)
  @heading_tags %{"h1" => "#", "h2" => "##", "h3" => "###", "h4" => "####", "h5" => "#####", "h6" => "######"}

  @req_headers [
    {"user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"},
    {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
    {"accept-language", "en-US,en;q=0.9"}
  ]

  # Paths that are almost never content pages
  @junk_paths ~w(
    /contact /about /login /signup /register /sign-in /sign-up
    /privacy /privacy-policy /terms /terms-of-service /tos /legal /disclaimer
    /cookie /cookie-policy /cookies /gdpr
    /cart /checkout /account /profile /settings /preferences /dashboard
    /search /sitemap /404 /500 /error
    /subscribe /unsubscribe /newsletter /feed /rss
    /wp-admin /wp-login /admin /cms
    /tag /tags /category /categories /author /authors /archive /archives
    /share /print /email /comment /comments /reply
    /help /support /faq /docs/api
    /careers /jobs /press /media /team /staff
  )

  # --- Public API ---

  @doc """
  Fetches a URL and extracts its main content as clean Markdown.

  Returns `{url, markdown}` on success or `{url, {:error, reason}}` on failure.

  ## Options

    * `:include_links` — preserve hyperlinks as `[text](url)` (default: `false`)
    * `:include_tables` — include table content as Markdown tables (default: `false`)

  ## Examples

      {_url, md} = Glean.scrape("https://example.com/article")
      {_url, md} = Glean.scrape("https://example.com/article", include_links: true)
  """
  @spec scrape(String.t(), [scrape_opt]) :: {String.t(), String.t() | {:error, String.t()}}
  def scrape(url, opts \\ []) do
    case fetch(url) do
      {:ok, html} ->
        md =
          html
          |> extract_main_content()
          |> to_markdown(opts)
          |> clean_markdown()

        {url, md}

      {:error, reason} ->
        {url, {:error, reason}}
    end
  end

  @doc """
  Discovers content links on a page using smart filtering.

  Returns `{links, stats}` where `links` is a list of URLs and `stats` is a map
  with discovery metadata (useful for deciding whether to switch to assisted mode).

  ## Filtering strategies (applied in order)

    1. **Content-area extraction** — prefers links found inside `<article>`, `<main>`,
       `[role=main]`, etc. Falls back to all page links if none found.
    2. **Junk blocklist** — skips ~40 common non-content paths (`/contact`, `/about`,
       `/login`, `/privacy`, `/cart`, etc.).
    3. **Pattern filter** — if `:pattern` is given, only keeps links whose path contains it.
    4. **Path affinity** — if no pattern given, prefers links sharing the seed URL's path prefix.

  ## Options

    * `:pattern` — only keep links whose path contains this string (e.g. `"/blog/"`)

  ## Stats map

    * `:content_area_count` — links found inside the main content area
    * `:total_count` — all same-domain links on the page
    * `:after_filter` — links remaining after all filters
    * `:pattern_used` — the pattern filter applied, or `nil`

  ## Examples

      {links, stats} = Glean.discover_links("https://example.com/blog")
      {links, _stats} = Glean.discover_links("https://example.com", pattern: "/docs/")
  """
  @spec discover_links(String.t(), [discover_opt]) :: {[String.t()], discover_stats}
  def discover_links(url, opts \\ []) do
    case fetch(url) do
      {:ok, html} ->
        {:ok, doc} = Floki.parse_document(html)
        base_uri = URI.parse(url)
        pattern = Keyword.get(opts, :pattern)

        # Gather links from content area first, fall back to full page
        {content_links, all_links} = extract_links(doc, base_uri)

        # Choose which link set to use
        raw_links = if content_links != [], do: content_links, else: all_links

        filtered =
          raw_links
          |> Enum.map(&resolve_url(&1, base_uri))
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(&same_domain?(&1, base_uri))
          |> Enum.map(&strip_fragment/1)
          |> Enum.uniq()
          |> Enum.reject(&non_page_url?/1)
          |> Enum.reject(&junk_path?/1)

        # Apply pattern filter or path affinity
        result =
          cond do
            pattern != nil ->
              Enum.filter(filtered, &url_matches_pattern?(&1, pattern))

            true ->
              apply_path_affinity(filtered, base_uri)
          end

        # Return both the filtered result and stats for the caller
        {result, %{
          content_area_count: length(content_links),
          total_count: length(all_links),
          after_filter: length(result),
          pattern_used: pattern
        }}

      {:error, _} ->
        {[], %{content_area_count: 0, total_count: 0, after_filter: 0, pattern_used: nil}}
    end
  end

  # Extract links separately from content area vs. whole page
  defp extract_links(doc, _base_uri) do
    content_selectors = ["article", "main", "[role=main]", ".post-content",
                         ".article-content", ".entry-content", ".content",
                         "#content", "#main"]

    content_nodes =
      Enum.find_value(content_selectors, fn sel ->
        case Floki.find(doc, sel) do
          [] -> nil
          nodes -> nodes
        end
      end)

    content_links =
      case content_nodes do
        nil -> []
        nodes ->
          nodes
          |> Floki.find("a")
          |> extract_hrefs()
      end

    all_links =
      doc
      |> Floki.find("a")
      |> extract_hrefs()

    {content_links, all_links}
  end

  defp extract_hrefs(anchor_nodes) do
    Enum.flat_map(anchor_nodes, fn {"a", attrs, _} ->
      case Enum.find_value(attrs, fn {k, v} -> if k == "href", do: v end) do
        nil -> []
        href -> [href]
      end
    end)
  end

  # --- URL Helpers ---

  defp resolve_url(href, base_uri) do
    href = String.trim(href)

    cond do
      String.starts_with?(href, "javascript:") -> nil
      String.starts_with?(href, "mailto:") -> nil
      String.starts_with?(href, "tel:") -> nil
      String.starts_with?(href, "#") -> nil
      String.starts_with?(href, "data:") -> nil
      true ->
        case URI.parse(href) do
          %URI{scheme: nil} ->
            URI.merge(base_uri, href) |> URI.to_string()
          %URI{scheme: scheme} when scheme in ["http", "https"] ->
            href
          _ ->
            nil
        end
    end
  end

  defp same_domain?(%URI{host: host}, %URI{host: base_host}), do: host == base_host
  defp same_domain?(url, base_uri) when is_binary(url), do: same_domain?(URI.parse(url), base_uri)

  defp strip_fragment(url) when is_binary(url) do
    uri = URI.parse(url)
    %URI{uri | fragment: nil} |> URI.to_string()
  end

  defp non_page_url?(url) do
    path = URI.parse(url).path || ""
    ext = Path.extname(path) |> String.downcase()
    ext in ~w(.pdf .png .jpg .jpeg .gif .svg .webp .mp4 .mp3 .zip .tar .gz .css .js .woff .woff2 .ttf .eot .ico .xml .json .rss .atom)
  end

  defp junk_path?(url) do
    path = URI.parse(url).path || ""
    normalized = path |> String.downcase() |> String.trim_trailing("/")
    normalized in @junk_paths
  end

  defp url_matches_pattern?(url, pattern) do
    path = URI.parse(url).path || ""
    String.contains?(path, pattern)
  end

  # Path affinity: if the seed URL has a meaningful path (e.g. /blog/..., /docs/...),
  # prefer links that share the same path prefix. If the seed is just "/", skip this.
  defp apply_path_affinity(links, base_uri) do
    seed_path = base_uri.path || "/"

    # Find the first meaningful path segment (e.g. /blog, /docs, /essays)
    prefix =
      case String.split(seed_path, "/", trim: true) do
        [] -> nil
        [first | _] ->
          # Only use prefix if it's not a single page (has no extension or is a directory-like path)
          if String.contains?(first, "."), do: nil, else: "/" <> first
      end

    case prefix do
      nil ->
        # No meaningful prefix — return all links, but deprioritize root-level paths
        # (like /about, /contact which the junk filter may have missed)
        {deep, shallow} = Enum.split_with(links, fn url ->
          path = URI.parse(url).path || "/"
          segments = String.split(path, "/", trim: true)
          length(segments) > 1
        end)
        deep ++ shallow

      prefix ->
        # Prefer links sharing the prefix, but include others as a secondary set
        {matching, other} = Enum.split_with(links, fn url ->
          path = URI.parse(url).path || ""
          String.starts_with?(path, prefix)
        end)

        if length(matching) >= 3 do
          # Good signal — use only the matching links
          matching
        else
          # Weak signal — include everything
          matching ++ other
        end
    end
  end

  # --- Fetch ---

  defp fetch(url) do
    case Req.get(url,
           headers: @req_headers,
           max_redirects: 5,
           receive_timeout: 15_000,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # --- Content Extraction ---

  defp extract_main_content(html) do
    {:ok, doc} = Floki.parse_document(html)
    doc = strip_elements(doc, @strip_tags)

    candidates = [
      Floki.find(doc, "article"),
      Floki.find(doc, "[role=main]"),
      Floki.find(doc, "main"),
      Floki.find(doc, ".post-content, .article-content, .entry-content, .content"),
      Floki.find(doc, "#content, #main, #article")
    ]

    case Enum.find(candidates, &(length(&1) > 0)) do
      nil -> Floki.find(doc, "body")
      found -> found
    end
  end

  defp strip_elements(nodes, tags) when is_list(nodes) do
    Enum.flat_map(nodes, fn node -> strip_elements_single(node, tags) end)
  end

  defp strip_elements_single({tag, attrs, children}, tags) do
    if tag in tags, do: [], else: [{tag, attrs, strip_elements(children, tags)}]
  end

  defp strip_elements_single(other, _tags), do: [other]

  # --- Markdown Conversion ---

  defp to_markdown(nodes, opts) when is_list(nodes) do
    nodes |> Enum.map(&node_to_md(&1, opts)) |> Enum.join("")
  end

  defp node_to_md({tag, _attrs, children}, opts) when is_map_key(@heading_tags, tag) do
    prefix = Map.get(@heading_tags, tag)
    text = inline_text(children, opts) |> String.trim()
    if text == "", do: "", else: "\n\n#{prefix} #{text}\n\n"
  end

  defp node_to_md({"p", _attrs, children}, opts) do
    text = inline_text(children, opts) |> String.trim()
    if text == "", do: "", else: "\n\n#{text}\n\n"
  end

  defp node_to_md({"blockquote", _attrs, children}, opts) do
    inner = to_markdown(children, opts) |> String.trim()

    if inner == "" do
      ""
    else
      quoted = inner |> String.split("\n") |> Enum.map(&"> #{&1}") |> Enum.join("\n")
      "\n\n#{quoted}\n\n"
    end
  end

  defp node_to_md({"ul", _attrs, children}, opts) do
    items =
      children
      |> Enum.filter(&match?({"li", _, _}, &1))
      |> Enum.map(fn {"li", _, kids} -> "- #{inline_text(kids, opts) |> String.trim()}" end)
      |> Enum.reject(&(&1 == "- "))
      |> Enum.join("\n")

    if items == "", do: "", else: "\n\n#{items}\n\n"
  end

  defp node_to_md({"ol", _attrs, children}, opts) do
    items =
      children
      |> Enum.filter(&match?({"li", _, _}, &1))
      |> Enum.with_index(1)
      |> Enum.map(fn {{"li", _, kids}, idx} -> "#{idx}. #{inline_text(kids, opts) |> String.trim()}" end)
      |> Enum.reject(&String.ends_with?(&1, ". "))
      |> Enum.join("\n")

    if items == "", do: "", else: "\n\n#{items}\n\n"
  end

  defp node_to_md({"pre", _attrs, children}, _opts) do
    text = Floki.text(children) |> String.trim()
    if text == "", do: "", else: "\n\n```\n#{text}\n```\n\n"
  end

  defp node_to_md({"hr", _attrs, _children}, _opts), do: "\n\n---\n\n"
  defp node_to_md({"br", _attrs, _children}, _opts), do: "\n"

  defp node_to_md({"table", _attrs, children}, opts) do
    if Keyword.get(opts, :include_tables, false), do: table_to_md(children, opts), else: ""
  end

  defp node_to_md({tag, _attrs, children}, opts) when tag in @block_tags do
    to_markdown(children, opts)
  end

  defp node_to_md({_tag, _attrs, children}, opts), do: inline_text(children, opts)
  defp node_to_md(text, _opts) when is_binary(text), do: text
  defp node_to_md(_, _opts), do: ""

  # --- Inline Text ---

  defp inline_text(nodes, opts) when is_list(nodes) do
    Enum.map(nodes, &inline_node(&1, opts)) |> Enum.join("")
  end

  defp inline_node(text, _opts) when is_binary(text), do: String.replace(text, ~r/\s+/, " ")

  defp inline_node({"strong", _attrs, children}, opts),
    do: "**#{inline_text(children, opts) |> String.trim()}**"

  defp inline_node({"b", _attrs, children}, opts),
    do: "**#{inline_text(children, opts) |> String.trim()}**"

  defp inline_node({"em", _attrs, children}, opts),
    do: "*#{inline_text(children, opts) |> String.trim()}*"

  defp inline_node({"i", _attrs, children}, opts),
    do: "*#{inline_text(children, opts) |> String.trim()}*"

  defp inline_node({"code", _attrs, children}, _opts),
    do: "`#{Floki.text(children) |> String.trim()}`"

  defp inline_node({"a", attrs, children}, opts) do
    text = inline_text(children, opts) |> String.trim()

    cond do
      text == "" ->
        ""

      Keyword.get(opts, :include_links, false) ->
        href = Enum.find_value(attrs, "", fn {k, v} -> if k == "href", do: v end)

        if href != "" and not String.starts_with?(href, "#"),
          do: "[#{text}](#{href})",
          else: text

      true ->
        text
    end
  end

  defp inline_node({"br", _, _}, _opts), do: "\n"
  defp inline_node({"img", _attrs, _children}, _opts), do: ""
  defp inline_node({_tag, _attrs, children}, opts), do: inline_text(children, opts)
  defp inline_node(_, _opts), do: ""

  # --- Table Support ---

  defp table_to_md(children, opts) do
    rows =
      children
      |> Floki.find("tr")
      |> Enum.map(fn {"tr", _, cells} ->
        Enum.map(cells, fn
          {cell_tag, _, kids} when cell_tag in ["td", "th"] ->
            inline_text(kids, opts) |> String.trim()
          _ -> ""
        end)
      end)

    case rows do
      [] ->
        ""

      [header | body] ->
        header_line = "| " <> Enum.join(header, " | ") <> " |"
        sep_line = "| " <> (Enum.map(header, fn _ -> "---" end) |> Enum.join(" | ")) <> " |"
        body_lines = Enum.map(body, fn row -> "| " <> Enum.join(row, " | ") <> " |" end)
        "\n\n" <> Enum.join([header_line, sep_line | body_lines], "\n") <> "\n\n"
    end
  end

  # --- Cleanup ---

  defp clean_markdown(text) do
    text |> String.replace(~r/\n{3,}/, "\n\n") |> String.trim()
  end
end

# --- CLI ---

{opts, urls, _} =
  OptionParser.parse(System.argv(),
    switches: [
      include_links: :boolean,
      include_tables: :boolean,
      crawl: :boolean,
      max_pages: :integer,
      pattern: :string,
      help: :boolean
    ],
    aliases: [l: :include_links, t: :include_tables, c: :crawl, p: :pattern, h: :help]
  )

if opts[:help] || urls == [] do
  IO.puts("""
  Usage: elixir glean.exs [OPTIONS] URL [URL...]

  Options:
    --include-links, -l    Preserve hyperlinks as [text](url)
    --include-tables, -t   Include table content
    --crawl, -c            Discover same-domain content links and scrape them too
    --pattern, -p PATTERN  Only crawl links whose path contains PATTERN (e.g. /blog/, /essays/)
    --max-pages N          Max pages to scrape in crawl mode (default: 50)
    -h, --help             Show this help

  Crawl uses smart filtering by default:
    - Only follows links found inside the main content area
    - Skips junk paths (/contact, /about, /login, /privacy, etc.)
    - Prefers links sharing the seed URL's path prefix
    - Use --pattern to override with an explicit filter
  """)

  System.halt(if(opts[:help], do: 0, else: 1))
end

scrape_opts = [
  include_links: opts[:include_links] || false,
  include_tables: opts[:include_tables] || false
]

max_pages = opts[:max_pages] || 50
pattern = opts[:pattern]

# If --crawl, discover subpages from each seed URL first
all_urls =
  if opts[:crawl] do
    discover_opts = if pattern, do: [pattern: pattern], else: []

    {seed_links, stats} =
      urls
      |> Task.async_stream(
        fn url ->
          Glean.discover_links(url, discover_opts)
        end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {links, stat}}, {all_links, all_stats} ->
          {all_links ++ links, [stat | all_stats]}
        _, acc ->
          acc
      end)

    all = (urls ++ seed_links) |> Enum.uniq() |> Enum.take(max_pages)

    # Report discovery stats
    total_found = stats |> Enum.map(& &1.total_count) |> Enum.sum()
    content_found = stats |> Enum.map(& &1.content_area_count) |> Enum.sum()

    IO.puts(:stderr, "Crawl: #{total_found} links on page, #{content_found} in content area, #{length(all)} after filtering")
    if pattern, do: IO.puts(:stderr, "Pattern filter: #{pattern}")

    all
  else
    urls
  end

multi = length(all_urls) > 1

results =
  all_urls
  |> Task.async_stream(
    fn url -> Glean.scrape(url, scrape_opts) end,
    max_concurrency: 20,
    timeout: 30_000
  )
  |> Enum.to_list()

any_success =
  Enum.any?(results, fn
    {:ok, {_url, text}} when is_binary(text) and text != "" -> true
    _ -> false
  end)

Enum.each(results, fn
  {:ok, {url, {:error, reason}}} ->
    IO.puts(:stderr, "Error: #{url}: #{reason}")

  {:ok, {url, text}} when is_binary(text) and text != "" ->
    if multi, do: IO.puts("\n--- #{url} ---\n")
    IO.puts(text)

  {:ok, {url, _}} ->
    IO.puts(:stderr, "Error: no content from #{url}")

  {:exit, reason} ->
    IO.puts(:stderr, "Error: task failed: #{inspect(reason)}")
end)

unless any_success, do: System.halt(1)
