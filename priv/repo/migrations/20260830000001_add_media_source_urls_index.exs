defmodule Bonfire.Files.Repo.Migrations.AddMediaSourceUrlsIndex do
  @moduledoc false
  use Ecto.Migration

  # CONCURRENTLY cannot run inside a transaction, and the migration lock also opens one
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    Bonfire.Files.Media.Migrations.add_media_source_urls_index()
  end

  def down do
    Bonfire.Files.Media.Migrations.drop_media_source_urls_index()
  end
end
