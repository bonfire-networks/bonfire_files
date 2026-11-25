defmodule Bonfire.Files.Repo.Migrations.BareLinkPreviewsQuoteLabels do
  use Ecto.Migration

  # runs the link preview cleanup again, now that a quote link named `RE: RE:` and an HTML anchor counts as having nothing to show
  def up() do
    # the migration's own repo, so the cleanup acts on the database being migrated
    EctoSparkles.DataMigration.Runner.run(
      Bonfire.Files.DataMigrations.BareLinkPreviews,
      repo: repo()
    )
  end

  def down, do: :ok
end
