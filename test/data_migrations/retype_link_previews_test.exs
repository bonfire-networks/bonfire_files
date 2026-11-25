defmodule Bonfire.Files.DataMigrations.RetypeLinkPreviewsTest do
  @moduledoc """
  A link preview saved before its kind was decided when it was saved (`Bonfire.Files.link_type/2`) has its page's Open Graph or oEmbed type for `media_type` (`article`, `video`, `rich`, `music.song`…): the backfill gives it `link`, `research`, `video/embed`, `audio/embed` or `document/embed`, as a new one gets. Files, and media of unknown type, are left alone.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Files.DataMigrations.RetypeLinkPreviews
  alias Bonfire.Files.Media

  @iframe ~s(<iframe src="https://player.example.com/embed/1"></iframe>)
  @wordpress ~s|<blockquote class="wp-embedded-content"><a href="https://blog.example.test/a/">A</a></blockquote><iframe src="https://blog.example.test/a/embed/"></iframe>|

  # {name, url, old media_type, metadata, the type it gets}
  @previews [
    youtube:
      {"https://www.youtube.com/watch?v=1", "video",
       %{"oembed" => %{"type" => "video", "html" => @iframe}}, "video/embed"},
    spotify:
      {"https://open.spotify.com/track/1", "rich",
       %{"oembed" => %{"type" => "rich", "html" => @iframe}}, "audio/embed"},
    wordpress:
      {"https://blog.example.test/a/", "article",
       %{
         "oembed" => %{"type" => "rich", "html" => @wordpress},
         "facebook" => %{"type" => "article"}
       }, "link"},
    paper:
      {"https://example.org/paper", "article", %{"other" => %{"citation_doi" => "10.1/abc"}},
       "research"},
    scribd:
      {"https://www.scribd.com/document/1/a", "website", %{"facebook" => %{"type" => "website"}},
       "document/embed"},
    song_page:
      {"https://example.org/song", "music.song", %{"facebook" => %{"type" => "music.song"}},
       "link"},
    odd_type:
      {"https://example.org/campaign", "gofundme:campaign",
       %{"facebook" => %{"type" => "gofundme:campaign"}}, "link"}
  ]

  # media the backfill leaves alone: a file, a remote file of unknown type, and a preview already typed
  @kept [
    file: {"https://example.org/a.png", "image/png", %{}},
    unknown: {"https://example.org/blob", "remote", %{}},
    embed: {"https://www.youtube.com/watch?v=2", "video/embed", %{}}
  ]

  setup do
    user = fake_user!()

    save = fn url, media_type, metadata ->
      {:ok, media} =
        Media.insert(user, url, %{media_type: media_type, size: 0}, %{
          url: url,
          media_type: media_type,
          metadata: metadata
        })

      media.id
    end

    previews =
      Map.new(@previews, fn {name, {url, media_type, metadata, _}} ->
        {name, save.(url, media_type, metadata)}
      end)

    kept =
      Map.new(@kept, fn {name, {url, media_type, metadata}} ->
        {name, save.(url, media_type, metadata)}
      end)

    %{previews: previews, kept: kept}
  end

  defp media_type(id), do: repo().one(from(m in Media, where: m.id == ^id, select: m.media_type))

  defp run, do: RetypeLinkPreviews.base_query() |> repo().all() |> RetypeLinkPreviews.migrate()

  test "gives each link preview the kind a new one gets, and leaves the rest", ctx do
    run()

    for {name, {_, _, _, expected}} <- @previews do
      assert media_type(ctx.previews[name]) == expected, "#{name} should be #{expected}"
    end

    for {name, {_, media_type, _}} <- @kept do
      assert media_type(ctx.kept[name]) == media_type, "#{name} should stay #{media_type}"
    end
  end

  test "running again changes nothing", ctx do
    run()
    before = Map.new(ctx.previews, fn {name, id} -> {name, media_type(id)} end)
    run()

    assert before == Map.new(ctx.previews, fn {name, id} -> {name, media_type(id)} end)
  end
end
