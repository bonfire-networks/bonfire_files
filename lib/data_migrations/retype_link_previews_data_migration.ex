defmodule Bonfire.Files.DataMigrations.RetypeLinkPreviews do
  @moduledoc """
  Gives each link preview saved before 25 November the `media_type` a new one gets (`Bonfire.Files.link_type/2`): `link`, `research`, a kind (`book`, `event`, `place`…), `video/embed`, `audio/embed` or `document/embed`, in place of its page's own Open Graph or oEmbed type (`article`, `video`, `rich`, `music.song`…), which stays in its metadata. So the feeds filter on one stored type and never on its metadata.

  Selects what isn't a file: a link-like `http` path, and a `media_type` with no `/` that isn't `remote` (a remote file of unknown type), `Image`, `Video`, `Audio` or `Document` (attachments). That includes previews already typed `link`, so they get a kind too. Safe to re-run: a retyped preview gets the same type again.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  alias Bonfire.Files.Media

  @not_previews ["remote", "Image", "Video", "Audio", "Document"]

  @impl DataMigration
  def base_query do
    from(m in Media,
      where:
        ilike(m.path, "http%") and is_nil(m.deleted_at) and
          fragment("position('/' in ?) = 0", m.media_type) and m.media_type not in @not_previews,
      select: %{id: m.id, path: m.path, media_type: m.media_type, metadata: m.metadata}
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      # in the background, so boot isn't blocked: on bonfire.cafe (25 November) about 600,000 Media match `base_query/0`
      async: true,
      batch_size: 1_000,
      throttle_ms: 200,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(rows), do: migrate(rows, [])

  # `opts[:repo]` is the repo the migration runs on (the migration passes its own `repo/0`), else the normal one
  @impl DataMigration
  def migrate(rows, opts) do
    repo = Keyword.get(opts, :repo, Bonfire.Common.Repo)

    rows
    |> Enum.group_by(&Bonfire.Files.link_type(&1.path, &1.metadata || %{}), & &1.id)
    |> Enum.each(fn {media_type, ids} ->
      {count, _} =
        repo.update_all(from(m in Media, where: m.id in ^ids), set: [media_type: media_type])

      info(count, "Retyped link previews as #{media_type}")
    end)

    :ok
  end
end
