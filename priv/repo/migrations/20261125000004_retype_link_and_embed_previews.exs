defmodule Bonfire.Files.Repo.Migrations.RetypeLinkAndEmbedPreviews do
  use Ecto.Migration

  # types again the link previews saved as `link`, `video/embed` or `audio/embed`, now that a news article's oEmbed card isn't taken for a player and a link gets its page's kind
  def up() do
    # the migration's own repo, so the change acts on the database being migrated
    EctoSparkles.DataMigration.Runner.run(
      Bonfire.Files.DataMigrations.RetypeLinkAndEmbedPreviews,
      repo: repo()
    )
  end

  def down, do: :ok
end
