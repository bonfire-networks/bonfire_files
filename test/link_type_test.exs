defmodule Bonfire.Files.LinkTypeTest do
  @moduledoc """
  A link preview's `media_type` says what a feed filter needs: `video/embed` or `audio/embed` for a link with a player we can embed, `research` for a paper, and `link` for anything else. The page's own Open Graph or oEmbed type stays in its metadata.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Files

  @iframe ~s(<iframe width="560" height="315" src="https://player.example.com/embed/1"></iframe>)

  # in the shape `Media.maybe_save/4` gets it from the fetch: atom keys for each source, string keys inside
  defp oembed(type, html), do: %{oembed: %{"type" => type, "html" => html}}

  test "a video page with an embeddable player is a video embed" do
    assert Files.link_type("https://www.youtube.com/watch?v=1", oembed("video", @iframe)) ==
             "video/embed"
  end

  test "a player on a known audio host is an audio embed, whatever the page calls itself" do
    spotify =
      ~s(<iframe style="border-radius:12px" src="https://open.spotify.com/embed/track/1" width="100%" height="152"></iframe>)

    assert Files.link_type("https://open.spotify.com/track/1", oembed("rich", spotify)) ==
             "audio/embed"

    # Acast says `video.other` in its Open Graph
    acast =
      oembed(
        "rich",
        ~s(<iframe src="https://embed.acast.com/show/episode" height="190"></iframe>)
      )
      |> Map.put(:facebook, %{"type" => "video.other"})

    assert Files.link_type("https://shows.acast.com/show/episodes/episode", acast) ==
             "audio/embed"
  end

  test "a player on a host with an audio platform's name in it is an audio embed" do
    assert Files.link_type(
             "https://open.audio.funkwhale.local/library/tracks/1",
             oembed("rich", @iframe)
           ) == "audio/embed"
  end

  test "an article embed (a quote of the post plus an iframe of it) is a link" do
    wordpress =
      ~s|<blockquote class="wp-embedded-content"><a href="https://blog.example.com/a/">A</a></blockquote><iframe class="wp-embedded-content" src="https://blog.example.com/a/embed/"></iframe>|

    assert Files.link_type(
             "https://blog.example.com/a/",
             oembed("rich", wordpress) |> Map.put(:facebook, %{"type" => "article"})
           ) == "link"
  end

  # as a news site gives it: a `rich` oEmbed whose only content is an iframe of a card of the article, no quote, on a page that says it's an article
  @article_card ~s(<iframe src="https://news.example.com/svc/oembed/html/?url=https%3A%2F%2Fnews.example.com%2F2026%2F11%2F13%2Fa-story.html" scrolling="no" frameborder="0" allowtransparency="true" title="A story" style="border:none;max-width:500px;min-width:300px;min-height:550px;display:block;width:100%;"></iframe>)

  test "a news article's oEmbed card (a rich iframe of the article) is a link" do
    url = "https://news.example.com/2026/11/13/a-story.html"

    # its Open Graph says article
    assert Files.link_type(
             url,
             oembed("rich", @article_card) |> Map.put(:facebook, %{"type" => "article"})
           ) == "link"

    # or only its JSON-LD does, as a list of objects
    assert Files.link_type(
             url,
             oembed("rich", @article_card)
             |> Map.put(:json_ld, [
               %{"@context" => "https://schema.org", "@type" => "NewsArticle", "@id" => url},
               %{"@type" => "BreadcrumbList"}
             ])
           ) == "link"

    # or a single JSON-LD object, of another kind of article
    assert Files.link_type(
             url,
             oembed("rich", @article_card) |> Map.put(:json_ld, %{"@type" => "BlogPosting"})
           ) == "link"
  end

  test "a page's JSON-LD type is read as one type or a list, by name or full IRI" do
    url = "https://news.example.com/2026/11/13/a-story.html"

    for type <- [
          ["NewsArticle", "Article"],
          "https://schema.org/NewsArticle",
          "http://schema.org/NewsArticle"
        ] do
      assert Files.link_type(
               url,
               oembed("rich", @article_card) |> Map.put(:json_ld, %{"@type" => type})
             ) == "link",
             "expected #{inspect(type)} to be read as an article"
    end

    # a video page's JSON-LD, as a list of types, with no oEmbed or Open Graph player
    assert Files.link_type("https://media.example.com/clip/1", %{
             json_ld: [%{"@type" => ["https://schema.org/VideoObject"]}]
           }) == "video/embed"

    # a paper by full IRI
    assert Files.link_type("https://example.org/a-paper", %{
             json_ld: %{"@type" => "http://schema.org/ScholarlyArticle"}
           }) == "research"
  end

  test "an article with a clip in it (its JSON-LD says article and video) is a link" do
    assert Files.link_type(
             "https://news.example.com/2026/11/13/a-story.html",
             oembed("rich", @article_card)
             |> Map.put(:json_ld, [%{"@type" => "NewsArticle"}, %{"@type" => "VideoObject"}])
           ) == "link"
  end

  test "control: a video page saying VideoObject, with an Open Graph player, is a video embed" do
    assert Files.link_type("https://video.example.com/v/2", %{
             facebook: %{"type" => "video.other", "video" => "https://video.example.com/embed/2"},
             json_ld: %{"@type" => "VideoObject"}
           }) == "video/embed"
  end

  # a page's kind, from its JSON-LD type (by name, IRI, or in a list) or, for books and profiles, its Open Graph type
  @kinds [
    {"research", %{json_ld: %{"@type" => "Thesis"}}},
    {"research", %{json_ld: [%{"@type" => "https://schema.org/Dataset"}]}},
    {"book", %{json_ld: %{"@type" => "Book"}}},
    {"book", %{json_ld: %{"@type" => "SequentialArt"}}},
    {"book", %{facebook: %{"type" => "book"}}},
    {"profile", %{json_ld: %{"@type" => "Person"}}},
    {"profile", %{json_ld: [%{"@type" => ["Organization", "NGO"]}]}},
    {"profile", %{json_ld: %{"@type" => "ProfilePage"}}},
    {"profile", %{facebook: %{"type" => "profile"}}},
    {"event", %{json_ld: %{"@type" => "Event"}}},
    {"event", %{json_ld: %{"@type" => "http://schema.org/MusicEvent"}}},
    {"recipe", %{json_ld: %{"@type" => "Recipe"}}},
    {"place", %{json_ld: %{"@type" => "Place"}}},
    {"place", %{json_ld: %{"@type" => "Museum"}}},
    {"product", %{json_ld: %{"@type" => "Product"}}},
    {"product", %{json_ld: %{"@type" => "Car"}}}
  ]

  test "a page is typed by the kind of thing its JSON-LD or Open Graph says it is" do
    for {kind, meta} <- @kinds do
      assert Files.link_type("https://example.com/page", meta) == kind,
             "expected #{inspect(meta)} to be #{kind}"
    end
  end

  test "a player comes first, then a paper, then an article, then the page's kind" do
    url = "https://example.com/page"

    # an audiobook with a player plays; without one it's a book
    assert Files.link_type(
             "https://open.spotify.com/show/1",
             oembed("rich", @iframe) |> Map.put(:json_ld, %{"@type" => "Audiobook"})
           ) == "audio/embed"

    assert Files.link_type(url, %{json_ld: %{"@type" => "Audiobook"}}) == "book"

    # an article that mentions a person is still an article
    assert Files.link_type(url, %{
             json_ld: [%{"@type" => "NewsArticle"}, %{"@type" => "Person"}]
           }) == "link"

    # a paper is research, though it's a kind of article
    assert Files.link_type(url, %{json_ld: %{"@type" => "ScholarlyArticle"}}) == "research"

    # a page about a film with no player is a link
    assert Files.link_type(url, %{json_ld: %{"@type" => "Movie"}}) == "link"
  end

  test "control: a rich iframe on a page that doesn't say it's an article is still a player" do
    assert Files.link_type(
             "https://media.example.com/clip/1",
             oembed("rich", @iframe) |> Map.put(:json_ld, [%{"@type" => "WebPage"}])
           ) == "video/embed"
  end

  test "a page without a player is a link, whatever its Open Graph type" do
    for og_type <- ["article", "website", "gofundme:campaign", "music.song", "video.movie"] do
      assert Files.link_type("https://example.com/page", %{facebook: %{"type" => og_type}}) ==
               "link",
             "expected #{og_type} to be a link"
    end
  end

  test "a video page with an Open Graph player URL and no oEmbed is a video embed" do
    assert Files.link_type("https://video.example.com/v/1", %{
             facebook: %{"type" => "video.other", "video" => "https://video.example.com/embed/1"}
           }) == "video/embed"
  end

  test "a link on a document host is a document embed, and one under it too" do
    for url <- [
          "https://www.scribd.com/document/123/a-report",
          "https://www.slideshare.net/someone/a-talk",
          "https://issuu.com/someone/docs/a-magazine",
          "https://speakerdeck.com/someone/a-talk"
        ] do
      assert Files.link_type(url, %{facebook: %{"type" => "article"}}) == "document/embed",
             "expected #{url} to be a document embed"
    end
  end

  # repositories are recognised by the open science extension, which not every flavour has
  if Code.ensure_loaded?(Bonfire.OpenScience) do
    test "a paper on a repository stays research, not a document" do
      assert Files.link_type("https://zenodo.org/records/123", %{}) == "research"
    end
  end

  test "control: a paper stays research" do
    assert Files.link_type("https://example.org/a-paper", %{
             "other" => %{"citation_doi" => "10.1234/abcd"}
           }) == "research"
  end
end
