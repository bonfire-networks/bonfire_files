defmodule Bonfire.Files.DataMigrations.RetypeLinkAndEmbedPreviews do
  @moduledoc """
  Types again each link preview saved as `link`, `video/embed` or `audio/embed`, as a new one is typed now (`Bonfire.Files.link_type/2`):
  - a news article's oEmbed card (a `rich` iframe of the article) was taken for a player, so it showed in the video feeds and as a player, and becomes a `link`; real players get the same type again;
  - a link to a page of a kind (an event, a book, a place…) gets that kind. `Bonfire.Files.DataMigrations.RetypeLinkPreviews` does this too, but an instance that ran it before links got their page's kind kept them as `link`.

  `RetypeLinkPreviews` only selects previews with no `/` in their type, so it doesn't reach the embeds. Safe to re-run.
  """

  import Ecto.Query
  alias EctoSparkles.DataMigration
  use DataMigration

  alias Bonfire.Files.Media

  @impl DataMigration
  def base_query do
    from(m in Media,
      where:
        ilike(m.path, "http%") and is_nil(m.deleted_at) and
          m.media_type in ["link", "video/embed", "audio/embed"],
      select: %{id: m.id, path: m.path, media_type: m.media_type, metadata: m.metadata}
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      # in the background, so boot isn't blocked: most link previews are `link`, so on a big instance this goes over most of the rows `RetypeLinkPreviews` does
      async: true,
      batch_size: 1_000,
      throttle_ms: 200,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(rows), do: migrate(rows, [])

  @impl DataMigration
  def migrate(rows, opts),
    do: Bonfire.Files.DataMigrations.RetypeLinkPreviews.migrate(rows, opts)
end
