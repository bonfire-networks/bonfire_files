defmodule Bonfire.Files.Repo.Migrations.RetypeLinkPreviews do
  use Ecto.Migration

  # gives each link preview the `media_type` a new one gets (`link`, `research`, `video/embed`, `audio/embed` or `document/embed`), instead of its page's own Open Graph or oEmbed type
  def up() do
    # the migration's own repo, so the change acts on the database being migrated
    EctoSparkles.DataMigration.Runner.run(
      Bonfire.Files.DataMigrations.RetypeLinkPreviews,
      repo: repo()
    )
  end

  def down, do: :ok
end
