defmodule Bonfire.Files.DataMigrations.RetypeLinkAndEmbedPreviewsTest do
  @moduledoc """
  A link preview typed `link`, `video/embed` or `audio/embed` when it was saved keeps that type until something types it again: the backfill gives each the type a new one gets now (`Bonfire.Files.link_type/2`), so a news article's oEmbed card typed as a video becomes a link, and a link to an event's page becomes an `event`. Players stay players, and files are left alone.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend
  import Ecto.Query
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Files.DataMigrations.RetypeLinkAndEmbedPreviews
  alias Bonfire.Files.Media

  @iframe ~s(<iframe src="https://player.example.com/embed/1"></iframe>)
  @article_card ~s(<iframe src="https://news.example.com/svc/oembed/html/?url=https%3A%2F%2Fnews.example.com%2Fa-story.html"></iframe>)

  # {name, url, media_type it was saved with, metadata, the type it gets}
  @previews [
    news_article:
      {"https://news.example.com/2026/11/13/a-story.html", "video/embed",
       %{
         "oembed" => %{"type" => "rich", "html" => @article_card},
         "facebook" => %{"type" => "article"},
         "json_ld" => [%{"@type" => "NewsArticle"}]
       }, "link"},
    youtube:
      {"https://www.youtube.com/watch?v=1", "video/embed",
       %{"oembed" => %{"type" => "video", "html" => @iframe}}, "video/embed"},
    spotify:
      {"https://open.spotify.com/track/1", "audio/embed",
       %{"oembed" => %{"type" => "rich", "html" => @iframe}}, "audio/embed"},
    # typed `link` by an instance that ran `RetypeLinkPreviews` before links got their page's kind
    event_page:
      {"https://tickets.example.com/e/1", "link", %{"json_ld" => [%{"@type" => "MusicEvent"}]},
       "event"}
  ]

  # media the backfill leaves alone: a file, and a link preview that is still a plain link
  @kept [
    file: {"https://example.org/a.mp4", "video/mp4", %{}},
    link: {"https://news.example.com/other.html", "link", %{"facebook" => %{"type" => "website"}}}
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

  defp run,
    do:
      RetypeLinkAndEmbedPreviews.base_query()
      |> repo().all()
      |> RetypeLinkAndEmbedPreviews.migrate()

  test "gives each link and embed preview the kind a new one gets, and leaves the rest", ctx do
    run()

    for {name, {_, _, _, expected}} <- @previews do
      assert media_type(ctx.previews[name]) == expected, "#{name} should be #{expected}"
    end

    for {name, {_, media_type, _}} <- @kept do
      assert media_type(ctx.kept[name]) == media_type, "#{name} should stay #{media_type}"
    end
  end
end
