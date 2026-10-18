defmodule Bonfire.Files.Repo.Migrations.MediaAutovacuumThresholds do
  @moduledoc """
  Per-table autovacuum thresholds for `bonfire_files_media`, as `Bonfire.Boundaries.Repo.Migrations.HotTablesAutovacuumThresholds` sets for the hottest tables.

  Media is append-mostly like them, so the default 20% triggers are never crossed and the table goes unvacuumed and unanalyzed. Observed in production: never analyzed at 136k rows, so the planner had no statistics for `metadata -> 'urls'`, chose a sequential scan over its GIN index (`20260830000001_add_media_source_urls_index`) for the link-preview dedup lookup, and timed out the post being published. `Bonfire.Files.Media.get_by_source_url/1` no longer depends on statistics to pick the index; this keeps them fresh for every other query on the table.

  Storage parameters only: no superuser needed, a brief SHARE UPDATE EXCLUSIVE lock, no rewrite. Guarded with `to_regclass` so an instance without the table migrates cleanly.
  """
  use Ecto.Migration

  @table "bonfire_files_media"

  @settings "autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.01, autovacuum_analyze_scale_factor = 0.01"
  @reset "autovacuum_vacuum_scale_factor, autovacuum_vacuum_insert_scale_factor, autovacuum_analyze_scale_factor"

  def up do
    execute """
    DO $$ BEGIN
      IF to_regclass('#{@table}') IS NOT NULL THEN
        EXECUTE 'ALTER TABLE #{@table} SET (#{@settings})';
      END IF;
    END $$
    """
  end

  def down do
    execute """
    DO $$ BEGIN
      IF to_regclass('#{@table}') IS NOT NULL THEN
        EXECUTE 'ALTER TABLE #{@table} RESET (#{@reset})';
      END IF;
    END $$
    """
  end
end
