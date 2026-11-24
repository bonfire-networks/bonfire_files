defmodule Bonfire.Files.Repo.Migrations.BareLinkPreviews do
  use Ecto.Migration

  # the link previews saved with nothing to show (a failed fetch, or a federated link named with its own URL), so the next post of each link fetches it again
  def up() do
    # the migration's own repo, so the cleanup acts on the database being migrated
    EctoSparkles.DataMigration.Runner.run(
      Bonfire.Files.DataMigrations.BareLinkPreviews,
      repo: repo()
    )
  end

  def down, do: :ok
end
