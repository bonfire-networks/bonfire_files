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

  test "a paper on a repository stays research, not a document" do
    assert Files.link_type("https://zenodo.org/records/123", %{}) == "research"
  end

  test "control: a paper stays research" do
    assert Files.link_type("https://doi.org/10.1234/abcd", %{
             other: %{"citation_doi" => "10.1234/abcd"}
           }) == "research"
  end
end
