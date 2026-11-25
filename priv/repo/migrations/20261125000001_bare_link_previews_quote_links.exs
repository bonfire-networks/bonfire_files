defmodule Bonfire.Files.Repo.Migrations.BareLinkPreviewsQuoteLinks do
  use Ecto.Migration

  # runs the link preview cleanup again, now that it also removes links to fediverse objects with nothing to show (quote Links saved as attachments)
  def up() do
    # the migration's own repo, so the cleanup acts on the database being migrated
    EctoSparkles.DataMigration.Runner.run(
      Bonfire.Files.DataMigrations.BareLinkPreviews,
      repo: repo()
    )
  end

  def down, do: :ok
end
